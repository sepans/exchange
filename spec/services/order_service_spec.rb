require 'rails_helper'
require 'support/gravity_helper'

describe OrderService, type: :services do
  include_context 'use stripe mock'
  include_context 'include stripe helper'
  let(:state) { Order::PENDING }
  let(:state_reason) { state == Order::CANCELED ? 'seller_lapsed' : nil }
  let(:order) { Fabricate(:order, external_charge_id: captured_charge.id, state: state, state_reason: state_reason, buyer_id: 'b123') }
  let!(:line_items) { [Fabricate(:line_item, order: order, artwork_id: 'a-1', list_price_cents: 123_00), Fabricate(:line_item, order: order, artwork_id: 'a-2', edition_set_id: 'es-1', quantity: 2, list_price_cents: 124_00)] }
  let(:user_id) { 'user-id' }

  describe 'create_with_artwork' do
    let(:buyer_id) { 'buyer_id' }
    let(:seller_id) { 'seller_id' }
    let(:artwork_id) { 'artwork_id' }
    let(:edition_set_id) { 'edition-set-id' }
    let(:order_mode) { Order::OFFER }

    context 'find_active_or_create=true' do
      let(:call_service) { OrderService.create_with_artwork!(buyer_id: buyer_id, buyer_type: Order::USER, mode: order_mode, quantity: 2, artwork_id: artwork_id, edition_set_id: edition_set_id, user_agent: 'ua', user_ip: '0.1', find_active_or_create: true) }

      context 'with existing order with same artwork/editionset/mode/quantity' do
        before do
          @existing_order = Fabricate(:order, buyer_id: buyer_id, buyer_type: Order::USER, seller_id: seller_id, seller_type: 'Gallery', mode: order_mode)
          @line_item = Fabricate(:line_item, order: @existing_order, artwork_id: artwork_id, edition_set_id: edition_set_id, quantity: 2)
        end

        it 'returns existing order' do
          expect do
            expect(call_service).to eq @existing_order
          end.not_to change(Order, :count)
        end

        it 'does not call statsd' do
          expect(Exchange).not_to receive(:dogstatsd)
          call_service
        end

        it 'wont queue OrderFollowUpJob' do
          call_service
          expect(OrderFollowUpJob).not_to have_been_enqueued
        end
      end
      context 'without existing order with same artwork/editionset/mode/quantity' do
        before do
          expect(Adapters::GravityV1).to receive(:get).with("/artwork/#{artwork_id}").once.and_return(gravity_v1_artwork)
        end

        it 'creates new order' do
          expect do
            order = call_service
            expect(order.mode).to eq order_mode
            expect(order.buyer_id).to eq buyer_id
            expect(order.seller_id).to eq 'gravity-partner-id'
            expect(order.line_items.count).to eq 1
            expect(order.line_items.pluck(:artwork_id, :edition_set_id, :quantity).first).to eq [artwork_id, edition_set_id, 2]
          end.to change(Order, :count).by(1).and change(LineItem, :count).by(1)
        end

        it 'reports to statsd' do
          expect(Exchange).to receive_message_chain(:dogstatsd, :increment).with('order.create')
          call_service
        end

        it 'queues OrderFollowUpJob' do
          call_service
          expect(OrderFollowUpJob).to have_been_enqueued
        end
      end
    end

    context 'find_active_or_create=false' do
      let(:call_service) { OrderService.create_with_artwork!(buyer_id: buyer_id, buyer_type: Order::USER, mode: order_mode, quantity: 2, artwork_id: artwork_id, edition_set_id: edition_set_id, user_agent: 'ua', user_ip: '0.1', find_active_or_create: false) }
      before do
        expect(Adapters::GravityV1).to receive(:get).with("/artwork/#{artwork_id}").once.and_return(gravity_v1_artwork)
      end

      context 'with existing order with same artwork/editionset/mode/quantity' do
        before do
          @existing_order = Fabricate(:order, buyer_id: buyer_id, buyer_type: Order::USER, seller_id: seller_id, seller_type: 'Gallery', mode: order_mode)
          @line_item = Fabricate(:line_item, order: @existing_order, artwork_id: artwork_id, edition_set_id: edition_set_id, quantity: 2)
        end

        it 'creates new order' do
          expect do
            order = call_service
            expect(order.mode).to eq order_mode
            expect(order.buyer_id).to eq buyer_id
            expect(order.seller_id).to eq 'gravity-partner-id'
            expect(order.line_items.count).to eq 1
            expect(order.line_items.pluck(:artwork_id, :edition_set_id, :quantity).first).to eq [artwork_id, edition_set_id, 2]
          end.to change(Order, :count).by(1).and change(LineItem, :count).by(1)
        end
      end

      context 'without existing order with same artwork/editionset/mode/quantity' do
        it 'creates new order' do
          expect do
            order = call_service
            expect(order.mode).to eq order_mode
            expect(order.buyer_id).to eq buyer_id
            expect(order.seller_id).to eq 'gravity-partner-id'
            expect(order.line_items.count).to eq 1
            expect(order.line_items.pluck(:artwork_id, :edition_set_id, :quantity).first).to eq [artwork_id, edition_set_id, 2]
          end.to change(Order, :count).by(1).and change(LineItem, :count).by(1)
        end

        it 'reports to statsd' do
          expect(Exchange).to receive_message_chain(:dogstatsd, :increment).with('order.create')
          call_service
        end

        it 'queues OrderFollowUpJob' do
          call_service
          expect(OrderFollowUpJob).to have_been_enqueued
        end
      end
    end
  end

  describe 'set_payment!' do
    let(:credit_card_id) { 'gravity-cc-1' }
    context 'order in pending state' do
      let(:state) { Order::PENDING }

      context "with a credit card id for the buyer's credit card" do
        let(:credit_card) { { id: credit_card_id, user: { _id: 'b123' } } }

        it 'sets credit_card_id on the order' do
          expect(Gravity).to receive(:get_credit_card).with(credit_card_id).and_return(credit_card)
          OrderService.set_payment!(order, credit_card_id)
          expect(order.reload.credit_card_id).to eq 'gravity-cc-1'
        end
      end

      context 'with a credit card id for credit card not belonging to the buyer' do
        let(:invalid_credit_card) { { id: credit_card_id, user: { _id: 'b456' } } }

        it 'raises an error' do
          expect(Gravity).to receive(:get_credit_card).with(credit_card_id).and_return(invalid_credit_card)
          expect { OrderService.set_payment!(order, credit_card_id) }.to raise_error do |error|
            expect(error).to be_a Errors::ValidationError
            expect(error.code).to eq :invalid_credit_card
          end
        end
      end
    end
  end

  describe 'fulfill_at_once!' do
    let(:fulfillment_params) { { courier: 'usps', tracking_id: 'track_this_id', estimated_delivery: 10.days.from_now } }

    context 'with order in approved state' do
      let(:state) { Order::APPROVED }

      it 'changes order state to fulfilled' do
        OrderService.fulfill_at_once!(order, fulfillment_params, user_id)
        expect(order.reload.state).to eq Order::FULFILLED
      end

      it 'creates one fulfillment model' do
        Timecop.freeze do
          expect { OrderService.fulfill_at_once!(order, fulfillment_params, user_id) }.to change(Fulfillment, :count).by(1)
          fulfillment = Fulfillment.last
          expect(fulfillment.courier).to eq 'usps'
          expect(fulfillment.tracking_id).to eq 'track_this_id'
          expect(fulfillment.estimated_delivery.to_date).to eq 10.days.from_now.to_date
        end
      end

      it 'sets all line items fulfillment to one fulfillment' do
        OrderService.fulfill_at_once!(order, fulfillment_params, user_id)
        fulfillment = Fulfillment.last
        line_items.each do |li|
          expect(li.fulfillments.first.id).to eq fulfillment.id
        end
      end

      it 'queues job to post fulfillment event' do
        OrderService.fulfill_at_once!(order, fulfillment_params, user_id)
        expect(PostEventJob).to have_been_enqueued.with('commerce', kind_of(String), 'order.fulfilled')
      end
    end

    Order::STATES.reject { |s| s == Order::APPROVED }.each do |state|
      context "order in #{state}" do
        let(:state) { state }
        it 'raises error' do
          expect do
            OrderService.fulfill_at_once!(order, fulfillment_params, user_id)
          end.to raise_error do |error|
            expect(error).to be_a Errors::ValidationError
            expect(error.code).to eq :invalid_state
          end
        end

        it 'does not add fulfillments' do
          expect do
            OrderService.fulfill_at_once!(order, fulfillment_params, user_id)
          end.to raise_error(Errors::ValidationError).and change(Fulfillment, :count).by(0)
        end
      end
    end
  end

  describe 'abandon!' do
    context 'order in pending state' do
      let(:state) { Order::PENDING }
      it 'abandons the order' do
        OrderService.abandon!(order)
        expect(order.reload.state).to eq Order::ABANDONED
      end

      it 'updates state_update_at' do
        Timecop.freeze do
          order.update!(state_updated_at: 10.days.ago)
          OrderService.abandon!(order)
          expect(order.reload.state_updated_at.to_date).to eq Time.now.utc.to_date
        end
      end

      it 'creates state history' do
        expect { OrderService.abandon!(order) }.to change(order.state_histories, :count).by(1)
      end
    end

    Order::STATES.reject { |s| s == Order::PENDING }.each do |state|
      context "order in #{state}" do
        let(:state) { state }
        it 'does not change state' do
          expect { OrderService.abandon!(order) }.to raise_error(Errors::ValidationError)
          expect(order.reload.state).to eq state
        end

        it 'raises error' do
          expect { OrderService.abandon!(order) }.to raise_error do |error|
            expect(error).to be_a Errors::ValidationError
            expect(error.type).to eq :validation
            expect(error.code).to eq :invalid_state
            expect(error.data).to match(state: state)
          end
        end
      end
    end
  end

  describe 'approve!' do
    let(:state) { Order::SUBMITTED }
    context 'buy now, capture payment_intent' do
      it 'raises error when approving wire transfer orders' do
        order.update!(payment_method: Order::WIRE_TRANSFER)
        expect { OrderService.approve!(order, user_id) }.to raise_error do |e|
          expect(e.code).to eq :unsupported_payment_method
        end
      end

      context 'failed stripe capture' do
        before do
          prepare_payment_intent_capture_failure(charge_error: { code: 'card_declined', decline_code: 'do_not_honor', message: 'The card was declined' })
        end
        it 'adds failed transaction and stays in submitted state' do
          expect { OrderService.approve!(order, user_id) }.to raise_error(Errors::ProcessingError).and change(order.transactions, :count).by(1)
          transaction = order.transactions.order(created_at: :desc).first
          expect(transaction).to have_attributes(
            status: Transaction::FAILURE,
            failure_code: 'card_declined',
            failure_message: 'Your card was declined.',
            decline_code: 'do_not_honor',
            external_id: 'pi_1',
            external_type: Transaction::PAYMENT_INTENT
          )
          expect(order.reload.state).to eq Order::SUBMITTED
          expect(OrderEvent).not_to receive(:delay_post)
          expect(OrderFollowUpJob).not_to receive(:set)
          expect(RecordSalesTaxJob).not_to receive(:perform_later)
        end
      end

      context 'with failed post_process' do
        it 'is in approved state' do
          prepare_payment_intent_capture_success
          allow(OrderEvent).to receive(:delay_post).and_raise('Perform what later?!')
          expect { OrderService.approve!(order, user_id) }.to raise_error(RuntimeError).and change(order.transactions, :count).by(1)
          expect(order.reload.state).to eq Order::APPROVED
        end
      end

      context 'with successful approval' do
        before do
          prepare_payment_intent_capture_success
          ActiveJob::Base.queue_adapter = :test
          expect { OrderService.approve!(order, user_id) }.to change(order.transactions, :count).by(1)
        end
        it 'adds successful transaction, updates the state and queues expected jobs' do
          expect(order.transactions.order(created_at: :desc).first).to have_attributes(
            status: Transaction::SUCCESS,
            external_id: 'pi_1',
            external_type: Transaction::PAYMENT_INTENT
          )
          expect(order.state).to eq Order::APPROVED
          expect(PostEventJob).to have_been_enqueued.with('commerce', kind_of(String), 'order.approved')
          expect(OrderFollowUpJob).to have_been_enqueued.with(order.id, Order::APPROVED)
          line_items.each { |li| expect(RecordSalesTaxJob).to have_been_enqueued.with(li.id) }
        end
      end
    end
  end

  describe '#reject!' do
    let(:state) { Order::SUBMITTED }
    let(:order_mode) { Order::BUY }

    context 'with a successful payment intent cancel' do
      before do
        prepare_payment_intent_cancel_success
        OrderService.reject!(order, user_id)
        # transaction = order.transactions.order(created_at: :desc).first
        # service.reject!
      end

      it 'queues undeduct inventory job for buy now order' do
        expect(UndeductLineItemInventoryJob).to have_been_enqueued.with(line_items.first.id)
      end

      it 'records the transaction' do
        transaction = order.transactions.order(created_at: :desc).first
        expect(transaction).to have_attributes(external_id: 'test_ch_3', transaction_type: Transaction::CANCEL, status: Transaction::SUCCESS)
      end

      it 'updates the order state' do
        expect(order.state).to eq Order::CANCELED
        expect(order.state_reason).to eq Order::REASONS[Order::CANCELED][:seller_rejected_other]
      end

      it 'queues notification job' do
        expect(PostEventJob).to have_been_enqueued.with('commerce', kind_of(String), 'order.canceled')
      end

      context 'offer order' do
        let(:order_mode) { Order::OFFER }
        let!(:line_items) { [Fabricate(:line_item, order: order, artwork_id: 'a-1', list_price_cents: 123_00)] }
        it 'does not queue undeduct inventory job for make offer order' do
          expect(UndeductLineItemInventoryJob).not_to have_been_enqueued
        end
      end
    end

    context 'with an unsuccessful payment intent cancelation' do
      before do
        prepare_payment_intent_cancel_failure(charge_error: { code: 'something', message: 'refund failed', decline_code: 'failed_refund' })
        expect { OrderService.reject!(order, user_id) }.to raise_error(Errors::ProcessingError).and change(order.transactions, :count).by(1)
      end

      it 'raises a ProcessingError and records the transaction' do
        transaction = order.transactions.order(created_at: :desc).first
        expect(transaction).to have_attributes(external_id: 'pi_1', transaction_type: Transaction::CANCEL, status: Transaction::FAILURE)
      end

      it 'does not queue undeduct inventory job' do
        expect(UndeductLineItemInventoryJob).not_to have_been_enqueued.with(line_items.first.id)
      end
    end

    context 'when the order is paid for by wire transfer' do
      it 'raises a ValidationError' do
        order.update!(payment_method: Order::WIRE_TRANSFER)
        expect { OrderService.reject!(order, user_id) }.to raise_error do |e|
          expect(e.code).to eq :unsupported_payment_method
        end
      end
    end

    context 'with an offer-mode order' do
      let!(:offer) { Fabricate(:offer, order: order, from_id: order.buyer_id, from_type: order.buyer_type) }
      # let(:service) { OrderCancellationService.new(order, 'seller') }

      before do
        # last_offer is set in Orders::InitialOffer. "Stubbing" out the
        # dependent behavior of this class to by setting last_offer directly
        order.update!(last_offer: offer, mode: 'offer')
      end

      describe 'with a submitted offer' do
        it 'updates the state of the order' do
          expect do
            OrderService.reject!(order, user_id, Order::REASONS[Order::CANCELED][:seller_rejected_offer_too_low])
          end.to change { order.state }.from(Order::SUBMITTED).to(Order::CANCELED)
                                       .and change { order.state_reason }
            .from(nil).to(Order::REASONS[Order::CANCELED][:seller_rejected_offer_too_low])
        end

        it 'instruments an rejected offer' do
          dd_statsd = stub_ddstatsd_instance
          expect(dd_statsd).to receive(:increment).with('order.reject')
          OrderService.reject!(order, user_id, Order::REASONS[Order::CANCELED][:seller_rejected_offer_too_low])
        end

        it 'sends a notification' do
          expect(PostEventJob).to receive(:perform_later).with('commerce', kind_of(String), 'order.canceled')
          OrderService.reject!(order, user_id, Order::REASONS[Order::CANCELED][:seller_rejected_offer_too_low])
        end
      end

      describe "when we can't reject the order" do
        let(:order) { Fabricate(:order, state: Order::PENDING) }
        let(:offer) { Fabricate(:offer, order: order) }

        it "doesn't instrument" do
          dd_statsd = stub_ddstatsd_instance
          allow(dd_statsd).to receive(:increment).with('offer.reject')

          expect { OrderService.reject!(order, user_id, Order::REASONS[Order::CANCELED][:seller_rejected_offer_too_low]) }.to raise_error(Errors::ValidationError)

          expect(dd_statsd).to_not have_received(:increment)
        end
      end
    end
  end

  xdescribe '#seller_lapse!' do
    context 'Buy Order' do
      context 'with a successful payment intent cancelation' do
        before do
          prepare_payment_intent_cancel_success
          service.seller_lapse!
        end

        it 'queues undeduct inventory job' do
          expect(UndeductLineItemInventoryJob).to have_been_enqueued.with(line_items.first.id)
        end

        it 'records the transaction' do
          transaction = order.transactions.order(created_at: :desc).first
          expect(transaction).to have_attributes(external_id: 'pi_1', external_type: Transaction::PAYMENT_INTENT, transaction_type: Transaction::CANCEL, status: Transaction::SUCCESS)
        end

        it 'updates the order state' do
          expect(order.state).to eq Order::CANCELED
          expect(order.state_reason).to eq Order::REASONS[Order::CANCELED][:seller_lapsed]
        end

        it 'queues notification job' do
          expect(PostEventJob).to have_been_enqueued.with('commerce', kind_of(String), 'order.canceled')
        end
      end

      context 'with an unsuccessful payment intent cancelation' do
        before do
          prepare_payment_intent_cancel_failure(charge_error: { code: 'something', message: 'refund failed', decline_code: 'failed_refund' })
          expect { OrderService.reject!(order, user_id) }.to raise_error(Errors::ProcessingError).and change(order.transactions, :count).by(1)
        end

        it 'raises a ProcessingError and records the transaction' do
          transaction = order.transactions.order(created_at: :desc).first
          expect(transaction).to have_attributes(external_id: 'pi_1', transaction_type: Transaction::CANCEL, status: Transaction::FAILURE)
        end

        it 'does not queue undeduct inventory job' do
          expect(UndeductLineItemInventoryJob).not_to have_been_enqueued.with(line_items.first.id)
        end
      end
    end

    context 'Offer Order' do
      let(:order_mode) { Order::OFFER }
      let!(:line_items) { [Fabricate(:line_item, order: order, artwork_id: 'a-1', list_price_cents: 123_00)] }

      before do
        prepare_payment_intent_refund_success
        service.seller_lapse!
      end

      it 'updates the order state' do
        expect(order.state).to eq Order::CANCELED
        expect(order.state_reason).to eq Order::REASONS[Order::CANCELED][:seller_lapsed]
      end

      it 'queues notification job' do
        expect(PostEventJob).to have_been_enqueued.with('commerce', kind_of(String), 'order.canceled')
      end
    end
  end

  xdescribe '#buyer_lapse!' do
    context 'Offer Order' do
      let(:order_mode) { Order::OFFER }
      let!(:line_items) { [Fabricate(:line_item, order: order, artwork_id: 'a-1', list_price_cents: 123_00)] }

      before do
        prepare_payment_intent_refund_success
        service.buyer_lapse!
      end

      it 'updates the order state' do
        expect(order.state).to eq Order::CANCELED
        expect(order.state_reason).to eq Order::REASONS[Order::CANCELED][:buyer_lapsed]
      end

      it 'queues notification job' do
        expect(PostEventJob).to have_been_enqueued.with('commerce', kind_of(String), 'order.canceled')
      end
    end
  end

  describe '#refund!' do
    [Order::APPROVED, Order::FULFILLED].each do |state|
      context "#{state} order" do
        let(:state) { state }

        context 'with a successful refund' do
          before do
            prepare_payment_intent_refund_success
            Fabricate(:transaction, order: order, external_id: 'test_ch_3', external_type: Transaction::PAYMENT_INTENT)
            OrderService.refund!(order, user_id)
          end

          it 'queues undeduct inventory job' do
            expect(UndeductLineItemInventoryJob).to have_been_enqueued.with(line_items.first.id)
          end

          it 'records the transaction' do
            transaction = order.transactions.order(created_at: :desc).first
            expect(transaction).to have_attributes(external_id: 're_1', transaction_type: Transaction::REFUND, status: Transaction::SUCCESS)
          end

          it 'updates the order state' do
            expect(order.state).to eq Order::REFUNDED
          end

          it 'queues notification job' do
            expect(PostEventJob).to have_been_enqueued.with('commerce', kind_of(String), 'order.refunded')
          end
        end

        context 'with an unsuccessful refund' do
          before do
            Fabricate(:transaction, order: order, external_id: 'test_ch_3', external_type: Transaction::PAYMENT_INTENT)
            prepare_payment_intent_refund_failure(code: 'something', message: 'refund failed', decline_code: 'failed_refund')
            expect {  OrderService.refund!(order, user_id) }.to raise_error(Errors::ProcessingError).and change(order.transactions, :count).by(1)
          end

          it 'raises a ProcessingError and records the transaction' do
            transaction = order.transactions.order(created_at: :desc).first
            expect(transaction).to have_attributes(external_id: 'pi_1', transaction_type: Transaction::REFUND, status: Transaction::FAILURE)
          end

          it 'does not queue undeduct inventory job' do
            expect(UndeductLineItemInventoryJob).not_to have_been_enqueued.with(line_items.first.id)
          end
        end

        context 'when the order is paid for by wire transfer' do
          it 'raises a ValidationError' do
            order.update!(payment_method: Order::WIRE_TRANSFER)
            expect { service.refund! }.to raise_error do |e|
              expect(e.code).to eq :unsupported_payment_method
            end
          end
        end
      end
    end
  end

  def stub_ddstatsd_instance
    dd_statsd = double(Datadog::Statsd)
    allow(Exchange).to receive(:dogstatsd).and_return(dd_statsd)

    dd_statsd
  end  
end
