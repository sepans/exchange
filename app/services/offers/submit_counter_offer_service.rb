module Offers
  class SubmitCounterOfferService
    attr_reader :offer
    def initialize(offer, user_id:)
      @offer = offer
      @order = offer.order
      @user_id = user_id
    end

    def process!
      validate_counter_offer!
      @order.with_lock do
        SubmitOfferService.new(@offer).process!
      end
      @order.update!(state_expires_at: @order.state_expires_at + 2.days)
      post_process!
    end

    private

    def validate_counter_offer!
      OrderValidator.validate_order_submitted!(offer.order)
    end

    def post_process!
      Exchange.dogstatsd.increment 'offer.counter'
    end
  end
end
