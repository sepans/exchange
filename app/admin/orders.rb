ActiveAdmin.register Order do
  actions :all, except: %i[create update destroy new edit]
  # TODO: change sort order
  config.sort_order = 'state_updated_at_desc'

  scope :all
  scope('Submitted', default: true) { |scope| scope.where(state: Order::SUBMITTED) }
  scope('Active', default: true) { |scope| scope.active }
  scope('Pickup') { |scope| scope.where(state: [ Order::APPROVED, Order::FULFILLED, Order::SUBMITTED ], fulfillment_type: Order::PICKUP ) }
  scope('Fulfillment Overdue') { |scope| scope.approved.where('state_expires_at < ?', Time.now) }
  scope('Completed') { |scope| scope.where(state: Order::FULFILLED) }
  scope('Case Closed') { |scope| scope.by_last_admin_note(AdminNote::TYPES[:case_closed]) }
  scope('Case Still Open') { |scope| scope.by_last_admin_note(AdminNote::TYPES.except(:case_closed).values) }

  filter :id_eq, label: 'Order Id'
  filter :mode, as: :check_boxes, collection: proc { Order::MODES }, label: 'Type'
  filter :code_eq, label: 'Order Code'
  filter :seller_id_eq, label: 'Seller Id'
  filter :buyer_id_eq, label: 'Buyer Id'
  filter :created_at, as: :date_range, label: 'Submitted Date'
  filter :fulfillment_type, as: :check_boxes, collection: proc { Order::FULFILLMENT_TYPES }
  filter :state, as: :check_boxes, collection: proc { Order::STATES }
  filter :state_reason, as: :check_boxes, collection: proc { Order::REASONS.values.map(&:values).flatten.uniq.map!(&:humanize) }
  filter :has_offer_note , as: :check_boxes, label: 'Has Offer Note'
  filter :assisted

  index do
    column :code do |order|
      link_to order.code, admin_order_path(order.id)
    end
    column 'Fulfillment', :fulfillment_type
    column :mode
    column :state
    column 'At' do |order|
      order.state_updated_at.strftime('%b %e')
    end
    column :state_expires_at
    column 'Items Total' do |order|
      format_money_cents(order.items_total_cents, currency_code: order.currency_code)
    end
  end

  member_action :refund, method: :post do
    # OrderCancellationService.new(resource).refund!
    OrderService.refund!(resource)
    redirect_to resource_path, notice: "Refunded!"
  end

  member_action :cancel, method: :post do
    # OrderCancellationService.new(resource, resource.buyer_id).reject!(Order::REASONS[Order::CANCELED][:admin_canceled])
    OrderService.reject!(resource, resource.buyer_id, Order::REASONS[Order::CANCELED][:admin_canceled])
    redirect_to resource_path, notice: "Canceled by Artsy admin!"
  end

  member_action :buyer_reject, method: :post do
    # OrderCancellationService.new(resource, resource.buyer_id).reject!(Order::REASONS[Order::CANCELED][:buyer_rejected])
    OrderService.reject!(resource, resource.buyer_id, Order::REASONS[Order::CANCELED][:buyer_rejected])
    redirect_to resource_path, notice: "Canceled on behalf of buyer!"
  end

  member_action :approve_order, method: :post do
    OrderService.approve!(resource, current_user[:id])
    redirect_to resource_path, notice: "Order approved!"
  end

  member_action :accept_offer, method: :post do
    return unless resource.mode == Order::OFFER && resource.state == Order::SUBMITTED
    OfferService.accept_offer(resource.last_offer, current_user[:id])
    redirect_to resource_path, notice: "Offer accepted!"
  end

  member_action :confirm_pickup, method: :post do
    if resource.fulfillment_type == Order::PICKUP
      OrderService.confirm_pickup!(resource, current_user[:id])
    end
    redirect_to resource_path, notice: "Fulfillment confirmed!"
  end

  member_action :confirm_fulfillment, method: :post do
    if resource.fulfillment_type == Order::SHIP
      OrderService.confirm_fulfillment!(resource, current_user[:id])
    end
    redirect_to resource_path, notice: "Fulfillment confirmed!"
  end

  member_action :toggle_assisted, method: :post do
    resource.toggle!(:assisted)
    redirect_to resource_path, notice: "toggled assisted flag!"
  end

  action_item :refund, only: :show do
    if [Order::APPROVED, Order::FULFILLED].include? order.state
      link_to 'Refund', refund_admin_order_path(order), method: :post, data: {confirm: 'Are you sure you want to refund this order?'}
    end
  end

  action_item :buyer_reject, only: :show do
    link_to 'Buyer Reject', buyer_reject_admin_order_path(order), method: :post, data: {confirm: 'Are you sure you want to reject this order on behalf of buyer?'} if order.state == Order::SUBMITTED
  end

  action_item :cancel_order, only: :show do
    link_to 'Cancel Order', cancel_admin_order_path(order), method: :post, data: {confirm: 'Are you sure you want to cancel this order?'} if order.state == Order::SUBMITTED
  end

  action_item :approve_order, only: :show do
    if order.state == Order::SUBMITTED && resource.mode == Order::BUY
      link_to 'Approve Order', approve_order_admin_order_path(order), method: :post, data: {confirm: 'Approve this order?'}
    end
  end

  action_item :accept_offer, only: :show do
    if order.state == Order::SUBMITTED && resource.mode == Order::OFFER
      link_to 'Accept Last Offer', accept_offer_admin_order_path(order), method: :post, data: {confirm: 'Accept last offer on this order?'}
    end
  end

  action_item :confirm_pickup, only: :show do
    if order.state == Order::APPROVED && order.fulfillment_type == Order::PICKUP
      link_to 'Confirm Pickup', confirm_pickup_admin_order_path(order), method: :post, data: {confirm: 'Confirm order pickup?'}
    end
  end

  action_item :confirm_fulfillment, only: :show do
    if order.state == Order::APPROVED && order.fulfillment_type == Order::SHIP
      link_to 'Confirm Fulfillment', confirm_fulfillment_admin_order_path(order), method: :post, data: {confirm: 'Confirm order fulfillment?'}
    end
  end

  action_item :toggle_assisted_flag, only: :show do
    if order.state != Order::PENDING
      link_to 'Toggle Assisted', toggle_assisted_admin_order_path(order), method: :post
    end
  end

  sidebar :contact_info, only: :show do

    table_for order.line_items do
      column '' do |line_item|
        artwork_info = Gravity.get_artwork(line_item.artwork_id)
        if artwork_info.present?
          if artwork_info[:images].kind_of?(Array)
            square_image = artwork_info[:images].find { |im| im[:image_urls].key?(:square) }
            if square_image
              img :src => square_image[:image_urls][:square], :width => "100%"
            end
          end
          br
          if artwork_info.key?(:title)
            link_to "#{artwork_info[:title]} by #{artwork_info[:artist][:name]}", artsy_view_artwork_url(line_item.artwork_id)
          end
        else
          h3 "Failed to fetch artwork"
        end
      end
    end

    panel "Buyer Information" do
      user_info = Gravity.get_user(order.buyer_id)

      attributes_table_for order do
        if user_info.present?
          row 'Name' do
            user_info[:name]
          end
          row 'Location' do
            if user_info[:location][:display].empty?
              div "No location for user"
            else
              user_info[:location][:display]
            end
          end
          row 'Email' do
            user_info[:email]
          end
        end
        if order.fulfillment_type == Order::SHIP
          row :shipping_name
          row :shipping_address do
            if order.shipping_info?
              div order.shipping_address_line1
              div order.shipping_address_line2
              div "#{order.shipping_city}, #{order.shipping_region} #{order.shipping_postal_code}"
              div order.shipping_country
            else
              'None'
            end
          end
          row 'Shipping Phone' do
            number_to_phone order.buyer_phone_number
          end
        end
      end
      if order.buyer_type == 'user'
        h5 link_to("View User in Admin", artsy_view_user_admin_url(order.buyer_id), class: :button)
      end

    end

    panel "Seller Information" do

      partner_info = Gravity.fetch_partner(order.seller_id)
      if partner_info.present?
        valid_partner_location = true
        begin
          partner_locations = Gravity.fetch_partner_locations(order.seller_id)
        rescue Errors::ValidationError
          valid_partner_location = false
        end

        if valid_partner_location
          #TODO - handle multiple partner_locations properly, instead of just taking the first.
          partner_location = partner_locations.first
          partner_info[:partner_location] = partner_location
          attributes_table_for partner_info do
            row :name
            row :partner_location do |partner_info|
              partner_location = partner_info[:partner_location]
              div partner_location.street_line1
              div partner_location.street_line2
              div "#{partner_location.city}, #{partner_location.region} #{partner_location.postal_code}"
            end
            row :email
          end
        else
          h3 "Failed to fetch partner location info"
        end
        h5 link_to("View Partner in Admin-Partners", artsy_view_partner_admin_url(order.seller_id), class: :button)
      else
        h3 "Failed to fetch partner info"
      end
    end
  end

  show do

    panel "Order Summary" do
      attributes_table_for order do
        row :code
        row 'Type' do |order|
          order.mode
        end
        row :state
        row 'Reason' do |order|
          order.state_reason
        end
        row 'Last Updated At' do |order|
          order.updated_at
        end

        last_admin_note = order.last_admin_note
        row 'Last admin action' do |order|
          if last_admin_note.present?
            last_admin_note.note_type.humanize
          end
        end
        row :assisted
        row 'Last note' do |order|
          if last_admin_note.present?
            last_admin_note.description
          end
        end

        row 'Last Transaction Failed' do |order|
          order.last_transaction_failed?
        end

        if order.state == Order::FULFILLED && order.fulfillment_type == Order::SHIP
          row 'Shipment' do |order|
            fulfillments = order.line_items.map(&:fulfillments).flatten
            table_for fulfillments do
              column '' do |fulfillment|
                attributes_table_for fulfillment do
                  row :courier
                  row :tracking_id
                  row :estimated_delivery
                end
              end
            end
          end
        end
      end
      br

      table_for order.state_histories do
        column 'Date', :created_at
        column :state
        column :reason
      end


    end

    if order.mode == Order::OFFER
      panel "Negotiation (#{order.offers.submitted.count})" do
        events = []

        order.offers.submitted.order(created_at: :desc).each do |offer|
          date = offer.created_at
          amount = format_money_cents(offer.amount_cents, currency_code: offer.order.currency_code)

          if order.state == Order::APPROVED && order.last_offer == offer
            events << {
              description: "#{offer.to_participant.capitalize} approved #{offer.from_participant}'s offer",
              amount: amount,
              date: date
            }
          end

          if offer.responds_to
            events << {
              description: "#{offer.from_participant.capitalize} made a counteroffer",
              amount: amount,
              date: date,
              note: offer.note
            }
          else
            events << {
              description: "Buyer made an initial offer",
              amount: amount,
              date: date,
              note: offer.note
            }
          end
        end
        table_for(events) do
          column 'Date', :date
          column 'Action', :description
          column 'Amount', :amount
          column 'Note', :note
        end
      end
    end

    panel "Transaction" do

      if order.credit_card_id.present?
        no_credit_card_found = false
        begin
          credit_card_info = Gravity.get_credit_card(order.credit_card_id)
          no_credit_card_found = !credit_card_info.present?
        rescue
          no_credit_card_found = true
        end
        if no_credit_card_found
          h5 "Paid #{format_money_cents(order.buyer_total_cents, currency_code: order.currency_code)} on #{pretty_format(order[:created_at])} (Failed to get credit card info)"
        else
          h5 "Paid #{format_money_cents(order.buyer_total_cents, currency_code: order.currency_code)} with #{credit_card_info[:brand]} ending in #{credit_card_info[:last_digits]} on #{pretty_format(order[:created_at])}"
        end
      end

      attributes_table_for order do
        row "Artwork List Price" do |_order|
          format_money_cents(order.total_list_price_cents, currency_code: order.currency_code)
        end
        row "Accepted Offer" do |_order|
          format_money_cents(order.items_total_cents, currency_code: order.currency_code)
        end if order.mode == Order::OFFER

        row "Shipping" do |order|
          format_money_cents(order.shipping_total_cents, currency_code: order.currency_code)
        end
        row "Sales Tax" do |order|
          format_money_cents(order.tax_total_cents, currency_code: order.currency_code)
        end
        row "Buyer Paid" do |order|
          format_money_cents(order.buyer_total_cents, currency_code: order.currency_code)
        end
        row "Processing Fee" do |order|
          format_money_cents(order.transaction_fee_cents, currency_code: order.currency_code, negate: true)
        end
        row "Artsy Fee" do |order|
          format_money_cents(order.commission_fee_cents, currency_code: order.currency_code, negate: true)
        end
        row "Seller Payout" do |order|
          format_money_cents(order.seller_total_cents, currency_code: order.currency_code)
        end

      end

      table_for order.transactions do
        column 'Date', :created_at
        column 'Type', :external_type
        column 'Action', :transaction_type
        column 'Status', :status
        column :failure_code
        column :failure_message
        column :decline_code
      end
    end

    panel "Admin Actions and Notes" do
      #TODO: Add "Add note" button
      h5 link_to("Add note", new_admin_order_admin_note_path(order), class: :button)
      table_for(order.admin_notes) do
        column :created_at
        column "Note Type" do |admin_note|
          admin_note.note_type.to_s.humanize
        end
        column :description
      end
    end
  end
end
