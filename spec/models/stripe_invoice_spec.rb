require 'rails_helper'
require 'stripe_helper'

RSpec.describe StripeInvoice, type: :model do
  describe 'self.create_for_account()' do
    context 'with account and invoice' do
      before :each do
        @account = build(:account)
        @stripe_event = build(:stripe_event, :invoice_finalized)
        @stripe_invoice = JSON.parse(@stripe_event.body)['data']['object']
        @inv = mock_model Invoice
      end

      it 'should create invoice for customer' do
        # Mock the Stripe API call for line items
        line_items_list = double(Stripe::ListObject)
        allow(Stripe::Invoice).to receive(:list_lines)
          .with(@stripe_invoice['id'], limit: 100)
          .and_return(line_items_list)
        allow(line_items_list).to receive(:auto_paging_each) do |&block|
          @stripe_invoice['lines']['data'].each { |item| block.call(item) }
        end

        expect(StripeInvoice).to receive(:create).with(account: @account,
                                                       stripe_invoice_id: @stripe_invoice['id']).and_return(@inv)
        expect(@inv).to receive(:create_line_items).with(@stripe_invoice['lines']['data'],
                                                         billing_reason: @stripe_invoice['billing_reason'])
        StripeInvoice.create_for_account(@account, @stripe_invoice)
      end
    end

    context 'with paginated line items (>10 items)' do
      before :each do
        @account = build(:account)
        @stripe_invoice_id = 'in_test_paginated_123'
        @stripe_invoice = { 'id' => @stripe_invoice_id, 'billing_reason' => 'subscription_cycle' }
        @inv = mock_model Invoice

        # Create 15 mock line items (simulating 2 pages: 10 + 5)
        @all_items = (1..15).map do |i|
          { 'id' => "il_#{i}", 'amount' => 1000 + i, 'description' => "Line item #{i}",
            'price' => { 'product' => "prod_#{i}" }, 'discount_amounts' => [] }
        end

        # Mock Stripe API pagination
        @list_page1 = double(Stripe::ListObject, has_more: true)
        allow(Stripe::Invoice).to receive(:list_lines)
          .with(@stripe_invoice_id, limit: 100).and_return(@list_page1)
        allow(@list_page1).to receive(:auto_paging_each) { |&block| @all_items.each { |item| block.call(item) } }
      end

      it 'should fetch all line items across multiple pages' do
        expect(StripeInvoice).to receive(:create).with(
          account: @account,
          stripe_invoice_id: @stripe_invoice_id
        ).and_return(@inv)

        # Verify all 15 items are passed to create_line_items
        expect(@inv).to receive(:create_line_items).with(
          @all_items,
          billing_reason: @stripe_invoice['billing_reason']
        )

        StripeInvoice.create_for_account(@account, @stripe_invoice)
      end
    end
  end

  describe 'self.link_to_invoice()' do
    context 'with Stripe invoice' do
      before :each do
        @stripe_event = build(:stripe_event, :invoice_finalized)
        @stripe_invoice = JSON.parse(@stripe_event.body)['data']['object']
        @stripe_invoice_id = @stripe_invoice['id']
      end

      context 'with invoice ID' do
        before :each do
          @invoice_id = 123
        end

        context 'and invoice exists' do
          before :each do
            @invoice = mock_model Invoice
            allow(Invoice).to receive(:find).with(@invoice_id).and_return @invoice
          end

          it 'should link the Stripe invoice to our invoice' do
            expect(@invoice).to receive(:stripe_invoice_id=).with @stripe_invoice_id
            expect(@invoice).to receive(:save)
            StripeInvoice.link_to_invoice(@invoice_id, @stripe_invoice)
          end
        end

        context 'and invoice does not exist' do
          before :each do
            allow(Invoice).to receive(:find).and_raise(ActiveRecord::RecordNotFound)
          end

          it 'should raise error' do
            expect { StripeInvoice.link_to_invoice(999, @stripe_invoice) }.to raise_error ArgumentError
          end
        end
      end
    end
  end

  describe 'self.create_payment()' do
    context 'with account and invoice' do
      before :each do
        @account = build(:account)
        @stripe_event = build(:stripe_event, :invoice_paid)
        @stripe_invoice = JSON.parse(@stripe_event.body)['data']['object']
        @inv = mock_model Invoice
      end

      it 'should create payment for invoice and mark it paid' do
        payments = double :payments

        allow(Invoice).to receive(:find_by).with(stripe_invoice_id: @stripe_invoice['id'])\
                                           .and_return(@inv)
        allow(@inv).to receive(:payments).and_return payments

        expect(payments).to receive(:create).with(
          account: @account,
          reference_number: @stripe_invoice['id'],
          date: Time.zone.at(@stripe_invoice['status_transitions']['paid_at']),
          method: 'Stripe',
          amount: @stripe_invoice['total'] / 100
        )
        expect(@inv).to receive('paid=').with(true)
        expect(@inv).to receive('save')

        StripeInvoice.create_payment(@account, @stripe_invoice)
      end

      context 'when Invoice not found' do
        before :each do
          allow(Invoice).to receive(:find).and_return nil
        end

        it 'should raise error' do
          expect { StripeInvoice.create_payment(@account, @stripe_invoice) }.to raise_error StandardError, /not found/
        end
      end
    end
  end

  describe 'self.charge_refunded_on' do
    context 'with charge' do
      before :each do
        # The JSON dance is to stringify the keys, which is how Stripe delivers them
        @stripe_event = JSON.parse(StripeFixtures.event_charge_refunded.to_json)
        @stripe_charge = @stripe_event['data']['object']
      end

      context 'when refunded' do
        it 'should return timestamp as string' do
          expect(StripeInvoice.charge_refunded_on(@stripe_charge)).to eq '2022-01-03 08:31:19 +0000'
        end
      end

      context 'when not refunded' do
        before :each do
          @stripe_charge['refunds']['data'] = []
        end

        it 'should return empty string' do
          expect(StripeInvoice.charge_refunded_on(@stripe_charge)).to eq ''
        end
      end

      context 'when anything else goes wrong' do
        before :each do
          allow(Time).to receive(:at).and_raise StandardError
        end

        it 'should return empty string' do
          expect(StripeInvoice.charge_refunded_on(@stripe_charge)).to eq ''
        end
      end
    end
  end

  describe 'self.charge_refunded_amount' do
    context 'with charge' do
      before :each do
        # The JSON dance is to stringify the keys, which is how Stripe delivers them
        @stripe_event = JSON.parse(StripeFixtures.event_charge_refunded.to_json)
        @stripe_charge = @stripe_event['data']['object']
      end

      context 'when refunded' do
        it 'should add up all the refund amounts and return the total' do
          expect(StripeInvoice.charge_refunded_amount(@stripe_charge)).to eq 10.00
        end
      end

      context 'when not refunded' do
        before :each do
          @stripe_charge['refunds']['data'] = []
        end

        it 'should return 0' do
          expect(StripeInvoice.charge_refunded_amount(@stripe_charge)).to eq 0.00
        end
      end
    end
  end

  describe 'self.process_refund()' do
    context 'with account and charge' do
      before :each do
        # The JSON dance is to stringify the keys, which is how Stripe delivers them
        @stripe_event = JSON.parse(StripeFixtures.event_charge_refunded.to_json)
        @stripe_charge = @stripe_event['data']['object']

        @inv = mock_model Invoice
      end

      it 'should set payment to zero, mark invoice unpaid, and return refunded amount' do
        payment = double :payment

        allow(Invoice).to receive(:find_by).with(stripe_invoice_id: @stripe_charge['invoice'])\
                                           .and_return(@inv)
        allow(@inv).to receive(:paid) { 10.0 }
        allow(@inv).to receive(:payments).and_return [payment]

        expect(@inv).to receive(:paid=).with(false)
        expect(@inv).to receive(:save)

        expect(payment).to receive(:amount=).with(0)
        expect(payment).to receive(:notes=)
        expect(payment).to receive(:save)

        refunded_amount = StripeInvoice.process_refund(@stripe_charge)
        expect(refunded_amount).to eq 10.0
      end

      context 'when Stripe refund amount is not equal to invoice payments' do
        before :each do
          allow(Invoice).to receive(:find_by).with(stripe_invoice_id: @stripe_charge['invoice'])\
                                             .and_return(@inv)
          allow(@inv).to receive(:paid) { 10.0 }
          @stripe_charge['refunds']['data'].first['amount'] = 5.0
        end

        it 'should raise error' do
          expect { StripeInvoice.process_refund(@stripe_charge) }.to raise_error StandardError
        end
      end

      context 'when Invoice not found' do
        before :each do
          allow(Invoice).to receive(:find).and_return nil
        end

        it 'should raise error' do
          expect { StripeInvoice.process_refund(@stripe_charge) }.to raise_error StandardError, /not found/
        end
      end
    end
  end

  describe 'create_line_items()' do
    context 'with invoice' do
      before :each do
        @inv = StripeInvoice.new
      end

      context 'with line items' do
        before :each do
          @stripe_event = build(:stripe_event, :invoice_finalized)
          @stripe_invoice = JSON.parse(@stripe_event.body)['data']['object']
          @stripe_line_items = @stripe_invoice['lines']['data']
          @first_stripe_line_item = @stripe_line_items.first
          @inv_line_item = mock_model InvoicesLineItem
          allow(@inv).to receive(:line_items).and_return(@inv_line_item)
        end

        context 'with metadata' do
          it 'should create line items with code in metadata' do
            @code = 'VPS'
            @prod = double(:stripe_product)
            @metadata = double(:metadata, product_code: @code)

            allow(Stripe::Product).to receive(:retrieve)\
              .with(id: @first_stripe_line_item['price']['product']).and_return @prod
            allow(@prod).to receive(:metadata).and_return @metadata

            expect(@inv_line_item).to receive(:create).with(
              code: @code,
              description: @first_stripe_line_item['description'],
              amount: @first_stripe_line_item['amount'] / 100
            )

            @inv.create_line_items(@stripe_line_items)
          end
        end

        context 'without metadata' do
          before :each do
            allow(Stripe::Product).to receive(:retrieve).and_raise StandardError
          end

          it 'should create line items with MISC code' do
            expect(@inv_line_item).to receive(:create).with(
              code: 'MISC',
              description: @first_stripe_line_item['description'],
              amount: @first_stripe_line_item['amount'] / 100
            )

            @inv.create_line_items(@stripe_line_items)
          end
        end

        context 'with billing_reason of manual' do
          before :each do
            @opts = {
              billing_reason: 'manual'
            }
          end

          it 'should write description with quantity' do
            @first_stripe_line_item['quantity'] = 3

            expect(@inv_line_item).to receive(:create).with(
              code: 'MISC',
              description: "3 × #{@first_stripe_line_item['description']}",
              amount: @first_stripe_line_item['amount'] / 100.0
            )

            @inv.create_line_items(@stripe_line_items, @opts)
          end
        end
      end
    end
  end

  describe 'create_discount_line_items()' do
    context 'with invoice' do
      before :each do
        @inv = StripeInvoice.new
      end

      context 'with line items' do
        before :each do
          @stripe_event = build(:stripe_event, :invoice_finalized)
          @stripe_invoice = JSON.parse(@stripe_event.body)['data']['object']
          @stripe_line_items = @stripe_invoice['lines']['data']
          @first_stripe_line_item = @stripe_line_items.first
          @inv_line_item = mock_model InvoicesLineItem
          allow(@inv).to receive(:line_items).and_return(@inv_line_item)
        end

        context 'with discount amounts' do
          before :each do
            @discount_amounts = []

            # This turns the keys into symbols, sigh...
            # @discount_amounts << {
            #   'amount': 100,
            #   'discount': 'di_1KAWWk2LsKuf8PTnjxDserXo'
            # }
            #
            # Must do it like this, wtf:
            @discount_amounts[0] = {}
            @discount_amounts[0]['amount'] = 100
            @discount_amounts[0]['discount'] = 'di_1KAWWk2LsKuf8PTnjxDserXo'
          end

          it 'should create line items with negative amount (discount)' do
            @code = 'VPS'

            expect(@inv_line_item).to receive(:create).with(code: @code, amount: -1.00, description: 'Discount')
            @inv.create_discount_line_items(@code, @discount_amounts)
          end
        end
      end
    end
  end
end
