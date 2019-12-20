module OrderService
  def self.create_with_artwork!(buyer_id:, buyer_type:, mode:, quantity:, artwork_id:, edition_set_id: nil, user_agent:, user_ip:, find_active_or_create: false)
    order_creator = OrderCreator.new(
      buyer_id: buyer_id,
      buyer_type: buyer_type,
      mode: mode,
      quantity: quantity,
      artwork_id: artwork_id,
      edition_set_id: edition_set_id,
      user_agent: user_agent,
      user_ip: user_ip
    )

    # in case of Offer orders, we want to reuse existing pending/submitted offers
    create_method = find_active_or_create ? :find_or_create! : :create!
    order_creator.send(create_method) do |created_order|
      Exchange.dogstatsd.increment 'order.create'
      OrderFollowUpJob.set(wait_until: created_order.state_expires_at).perform_later(created_order.id, created_order.state)
    end
  end

  def self.set_shipping!(order, fulfillment_type:, shipping:)
    raise Errors::ValidationError, :invalid_state unless order.state == Order::PENDING

    order_shipping = OrderShipping.new(order)
    case fulfillment_type
    when Order::PICKUP then order_shipping.pickup!(shipping&.dig(:phone_number))
    when Order::SHIP then order_shipping.ship!(shipping)
    end
    order
  end

  def self.set_payment!(order, credit_card_id)
    credit_card = Gravity.get_credit_card(credit_card_id)
    raise Errors::ValidationError.new(:invalid_credit_card, credit_card_id: credit_card_id) unless credit_card.dig(:user, :_id) == order.buyer_id

    # nilify external_charge_id in case we had in progress payment intent so we create a new one
    order.update!(credit_card_id: credit_card_id, external_charge_id: nil)
    order
  end

  def self.submit!(order, user_id)
    unless order.valid_artwork_version?
      Exchange.dogstatsd.increment 'submit.artwork_version_mismatch'
      raise Errors::ProcessingError, :artwork_version_mismatch
    end

    order_processor = OrderProcessor.new(order, user_id)
    raise Errors::ValidationError, order_processor.validation_error unless order_processor.valid?

    order_processor.advance_state(:submit!)
    unless order_processor.deduct_inventory
      order_processor.revert!
      raise Errors::InsufficientInventoryError
    end

    order_processor.set_totals!
    order_processor.hold
    order_processor.store_transaction

    raise Errors::FailedTransactionError.new(:charge_authorization_failed, order_processor.transaction) if order_processor.failed_payment?

    if order_processor.requires_action?
      Exchange.dogstatsd.increment 'submit.requires_action'
      raise Errors::PaymentRequiresActionError, order_processor.action_data
    end
    order_processor.on_success
    order
  rescue StandardError => e
    # catch all
    order_processor&.revert!
    raise e
  end

  def self.approve!(order, user_id)
    raise Errors::ValidationError.new(:unsupported_payment_method, order.payment_method) unless order.payment_method == Order::CREDIT_CARD

    payment_service = PaymentService.new(order)
    transaction = nil
    order.approve! do
      transaction = payment_service.capture_hold
      raise Errors::ProcessingError.new(:capture_failed, transaction.failure_data) if transaction.failed?
    end

    order.line_items.each { |li| RecordSalesTaxJob.perform_later(li.id) }
    OrderEvent.delay_post(order, user_id)
    OrderFollowUpJob.set(wait_until: order.state_expires_at).perform_later(order.id, order.state)
    ReminderFollowUpJob.set(wait_until: order.state_expiration_reminder_time).perform_later(order.id, order.state)
    Exchange.dogstatsd.increment 'order.approve'
    Exchange.dogstatsd.count('order.money_collected', order.buyer_total_cents)
    Exchange.dogstatsd.count('order.commission_collected', order.commission_fee_cents)
  ensure
    order.transactions << transaction if transaction.present?
  end

  def self.fulfill_at_once!(order, fulfillment, user_id)
    order.fulfill! do
      fulfillment = Fulfillment.create!(fulfillment.slice(:courier, :tracking_id, :estimated_delivery))
      order.line_items.each do |li|
        li.line_item_fulfillments.create!(fulfillment_id: fulfillment.id)
      end
    end
    OrderEvent.delay_post(order, user_id)
    order
  end

  def self.confirm_pickup!(order, user_id)
    raise Errors::ValidationError, :wrong_fulfillment_type unless order.fulfillment_type == Order::PICKUP

    order.fulfill!
    OrderEvent.delay_post(order, user_id)
    order
  end

  def self.confirm_fulfillment!(order, user_id)
    raise Errors::ValidationError, :wrong_fulfillment_type unless order.fulfillment_type == Order::SHIP

    order.fulfill!
    OrderEvent.delay_post(order, user_id)
    order
  end

  def self.refund!(order, user_id)
    cancelation_helper = CancelationHelper.new(order)
    transaction = nil
    order.refund! do
      transaction = cancelation_helper.process_stripe_refund
    end
    cancelation_helper.record_stats
    cancelation_helper.process_inventory_undeduction
    OrderEvent.delay_post(order, user_id)
  ensure
    order.transactions << transaction if transaction.present?
  end

  def self.reject!(order, user_id, rejection_reason = nil)
    transaction = nil
    cancelation_helper = CancelationHelper.new(order)
    order.reject!(rejection_reason) do
      transaction = cancelation_helper.cancel_payment_intent if order.mode == Order::BUY
    end
    cancelation_helper.process_inventory_undeduction if order.mode == Order::BUY
    Exchange.dogstatsd.increment 'order.reject'
    OrderEvent.delay_post(order, user_id)
  ensure
    order.transactions << transaction if transaction.present?
  end

  def self.abandon!(order)
    order.abandon!
  end
end
