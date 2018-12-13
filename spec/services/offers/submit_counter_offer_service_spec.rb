require 'rails_helper'
require 'support/gravity_helper'

describe Offers::SubmitCounterOfferService, type: :services do
  describe '#process!' do
    let(:offer_from_id) { 'user-id' }
    let(:order_seller_id) { 'partner-1' }
    let(:order) { Fabricate(:order, state: Order::SUBMITTED, seller_id: order_seller_id) }
    let!(:line_item) { Fabricate(:line_item, order: order) }
    let(:offer) { Fabricate(:offer, order: order, amount_cents: 10000, submitted_at: 1.day.ago) }
    let(:pending_offer) { Fabricate(:offer, order: order, amount_cents: 20000, responds_to: offer, from_id: offer_from_id) }
    let(:service) { Offers::SubmitCounterOfferService.new(pending_offer, user_id: offer_from_id) }
    let(:offer_total_updater_service) { double }

    before do
      # last_offer is set in Orders::InitialOffer. "Stubbing" out the
      # dependent behavior of this class to by setting last_offer directly
      order.update!(last_offer: offer)
      allow(Adapters::GravityV1).to receive(:get).with("/partner/#{order_seller_id}/all").and_return(gravity_v1_partner)
    end

    context 'with a submitted offer' do
      it 'submits the pending offer and updates last offer' do
        state_expiration_before = order.state_expires_at
        service.process!
        expect(order.offers.count).to eq(2)
        expect(order.last_offer).to eq(pending_offer)
        expect(order.last_offer.amount_cents).to eq(20000)
        expect(order.last_offer.responds_to).to eq(offer)
        expect(pending_offer.submitted_at).not_to be_nil
        expect(order.reload.state_expires_at.to_i).to eq((state_expiration_before + Order::STATE_EXPIRATIONS['submitted']).to_i)
      end

      it 'instruments a counter offer' do
        dd_statsd = stub_ddstatsd_instance
        allow(dd_statsd).to receive(:increment).with('offer.counter')

        service.process!

        expect(dd_statsd).to have_received(:increment).with('offer.counter')
      end
    end

    context 'attempting to submit already submitted offer' do
      let(:pending_offer) { Fabricate(:offer, order: order, amount_cents: 20000, responds_to: offer, submitted_at: 1.minute.ago, from_id: offer_from_id) }
      it 'raises a validation error' do
        expect {  service.process! }
          .to raise_error(Errors::ValidationError)
      end

      it 'does not instrument' do
        dd_statsd = stub_ddstatsd_instance
        allow(dd_statsd).to receive(:increment).with('order.counter')

        expect {  service.process! }.to raise_error(Errors::ValidationError)

        expect(dd_statsd).to_not have_received(:increment)
      end
    end

    context 'attempting to submit someone elses offer' do
      let(:pending_offer) { Fabricate(:offer, order: order, amount_cents: 20000, responds_to: offer, submitted_at: 1.minute.ago, from_id: 'al-pachino') }
      it 'raises a validation error' do
        expect {  service.process! }
          .to raise_error(Errors::ValidationError)
      end

      it 'does not instrument' do
        dd_statsd = stub_ddstatsd_instance
        allow(dd_statsd).to receive(:increment).with('order.counter')

        expect {  service.process! }.to raise_error(Errors::ValidationError)

        expect(dd_statsd).to_not have_received(:increment)
      end
    end

    def stub_ddstatsd_instance
      dd_statsd = double(Datadog::Statsd)
      allow(Exchange).to receive(:dogstatsd).and_return(dd_statsd)

      dd_statsd
    end
  end
end
