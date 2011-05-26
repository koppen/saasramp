module Saasramp
  module Subscription
    def self.included(base)
      base.belongs_to :subscriber, :polymorphic => true
      base.belongs_to :plan, :class_name => 'SubscriptionPlan'
      base.has_one :profile, :class_name => 'SubscriptionProfile', :dependent => :destroy
      base.has_many :transactions, :class_name => 'SubscriptionTransaction', :dependent => :destroy, :order => 'id DESC' #created_at is in seconds not microseconds?! so assume higher id's are newer

      base.composed_of :balance, :class_name => 'Money', :allow_nil => true,
        :mapping => [%w(balance_cents cents), %w(currency currency_as_string)],
        :constructor => Proc.new { |cents, currency| Money.new(cents || 0, currency || SubscriptionConfig.currency) }

      base.before_validation :initialize_defaults
      base.after_create      :initialize_state_from_plan
      # if you destroy a subscription all transaction history is lost so you may not really want to do that
      base.before_destroy    :cancel

      base.attr_accessible # none

      # states: :pending, :free, :trial, :active, :past_due, :expired
      base.state_machine :state, :initial => :pending do 
        # set next renewal date when entering a state
        before_transition any => :free,     :do => :setup_free
        before_transition any => :trial,    :do => :setup_trial
        before_transition any => :active,   :do => :setup_active

        # always reset warning level when entering a different state
        before_transition any => any do |sub, transition|
          sub.warning_level = nil unless transition.from == transition.to
        end

        # for simpicity, event names are the same as the state
        event :free do
          transition any => :free
        end
        event :trial do
          transition [:pending, :free] => :trial
        end
        event :active do
          transition any => :active
        end
        event :past_due do
          from = any - [:expired]
          transition from => :past_due, :if => Proc.new {|s| s.due? }
        end
        event :expired do
          transition any => :expired
        end

      end

      # named scopes
      # used in daily rake task
      # note, 'due' scopes find up to and including the specified day
      base.named_scope :due_now, lambda { 
        { :conditions => ["next_renewal_on <= ?", Time.zone.today] }
      }
      base.named_scope :due_on, lambda {|date|
        { :conditions => ["next_renewal_on <= ?", date] }
      }
      base.named_scope :due_in, lambda {|days|
        { :conditions => ["next_renewal_on <= ?", Time.zone.today + days] }
      }
      base.named_scope :due_ago, lambda {|days|
        { :conditions => ["next_renewal_on <= ?", Time.zone.today - days] }
      }
      base.named_scope :with_no_warnings, lambda {
        { :conditions => { :warning_level => nil } }
      }
      base.named_scope :with_warning_level, lambda {|level|
        { :conditions => { :warning_level => level } }
      }

      base.send(:include, InstanceMethods)
    end

    module ClassMethods
      def cm; puts 'I am a class method'; end
    end

    module InstanceMethods
      def setup_free
        self.next_renewal_on = nil 
      end

      def setup_trial
        start = Time.zone.today
        self.next_renewal_on = start + SubscriptionConfig.trial_period.days
      end

      def setup_active
        # next renewal is from when subscription ran out (to change this behavior, set next_renewal to nil before doing renew)
        start = next_renewal_on || Time.zone.today
        self.next_renewal_on = start + plan.interval.months
      end

      # returns nil if not past due, false for failed, true for success, or amount charged for success when card was charged
      def renew(options = {})
        # make sure it's time
        return nil unless due?
        transaction do # makes this atomic
          #debugger

          # adjust current balance (except for re-tries)
          self.balance += plan.rate unless past_due?

          unless has_profile?
            # Subscriber doesn't have credit card details so we can't possibly charge them. Don't
            # even try, just make the subscription past_due and notify the subscriber
            past_due
            notify_subscriber_of_charge_failure!
            return false
          end

          # charge the amount due

          # Ask the plan for a human readable description of the transaction
          description = self.plan.description_for_renewal_charge if self.plan.respond_to?(:description_for_renewal_charge)

          # charge_balance returns false if user has no profile.
          # It also creates the SubscriptionTransaction that triggers the email delivery
          case charge = charge_balance({:description => description}.merge(options))

          # transaction failed: past due and return false
          when false:   past_due && false

          # not charged, subtracted from current balance: update renewal and return true
          when nil:     active && true

          # card was charged: update renewal and return amount
          else          active && charge
          end
        end
      end

      # cancelling can mean revert to a free plan and credit back their card
      # if it also means destroying or disabling the user account, that happens elsewhere in your app 
      # returns same results as change_plan (nil, false, true)
      def cancel
        change_plan SubscriptionPlan.default_plan
        # uncomment if you want to refund unused value to their credit card, otherwise it just says on balance here
        #credit_balance
      end

      # ------------
      # changing the subscription plan
      # usage: e.g in a SubscriptionsController
      # if !@subscription.exceeds_plan?( plan )  &&  @subscription.change_plan( plan )
      #   @subscription.renew
      # end
      #
      # the #change_plan method sets the new current plan, 
      # prorates unused service from previous billing
      # billing cycle for the new plan starts today
      # if was in trial, stays in trial until the trial period runs out
      # note, you should call #renew right after this
      #
      # returns nil if no change, false if failed, or true on success
      def change_plan( new_plan )
        # not change?
        return if plan == new_plan

        # return unused prepaid value on current plan
        self.balance -= plan.prorated_value( days_remaining ) if active?
        # or they owe the used (although unpaid) value on current plan [comment out if you want to be more forgiving]
        self.balance -= plan.rate - plan.prorated_value( past_due_days ) if past_due?

        # update the plan
        self.plan = new_plan

        # update the state and initialize the renewal date
        if plan.free?
          self.free

        elsif (e = trial_ends_on)
          self.trial
          self.next_renewal_on = e #reset end date

        else #active or past due
          # note, past due grace period resets like active ones due today, ok?
          self.active
          self.next_renewal_on = Time.zone.today
          self.warning_level = nil
        end
        # past_due and expired fall through till next renew

        # save changes so far
        save
      end

      # list of plans this subscriber is allowed to choose
      # use the subscription_plan_check callback in subscriber model
      def allowed_plans
        SubscriptionPlan.all.collect {|plan| plan unless exceeds_plan?(plan) }.compact
      end

      # test if subscriber can use a plan, returns true or false
      def exceeds_plan?( plan = self.plan)
        !(plan_check(plan).blank?)
      end

      # check if subscriber can use a plan and returns list of attributes exceeded, or blank for ok
      def plan_check( plan = self.plan)
        subscriber.subscription_plan_check(plan)
      end

      # Delivers the [second_]charge_failure emails to the subscriber and increments the
      # warning_level accordingly.
      def notify_subscriber_of_charge_failure!(transaction = nil)
        self.increment!(:warning_level)

        # Don't notify subscriber if it'll result in an error
        return unless self.subscriber && self.subscriber.respond_to?(:email) && self.subscriber.email.present?

        case self.warning_level
        when 1
          SubscriptionConfig.mailer.deliver_charge_failure(self)
        when 2
          SubscriptionConfig.mailer.deliver_second_charge_failure(self)
        end
      end

      # Returns true if Subscription has credit card details
      def has_profile?
        profile.present? && !profile.no_info? && profile.profile_key.present?
      end

      # charge the current balance against the subscribers credit card
      # return amount charged on success, false for failure, nil for nothing happened
      def charge_balance(options = {})
        options.symbolize_keys!
        #debugger
        # nothing to charge? (0 or a credit)
        return if balance_cents <= 0

        # no card on file
        unless has_profile?
          notify_subscriber_of_charge_failure!
          return false
        end

        transaction do # makes this atomic
          #debugger
          # charge the card
          tx  = SubscriptionTransaction.charge( balance, profile.profile_key )
          tx.description = options[:description] unless options[:description].blank?
          # save the transaction
          transactions.push( tx )
          # set profile state and reset balance
          if tx.success
            self.update_attribute :balance_cents, 0
            profile.authorized
          else
            profile.error
          end
          tx.success && tx.amount
        end
      end

      def receive_notification(notification)
        puts "Hurray! We received a payment of #{notification.amount.format}"
        transaction do

          # make sure transaction does not exist
          existing_ref = SubscriptionTransaction.find_by_reference(notification.merchant_reference)
          unless existing_ref
            # create record for transction
            tx  = SubscriptionTransaction.receive_notification( notification )
            transactions.push( tx )

            # We have to do something with the credit card
            # "paymentMethod"=>"visa"
            profile.store_card_token(notification.payment_method, notification.psp_reference)

            # adjust current balance (except for re-tries)
            self.balance += notification.amount

          else
            puts "There is a transcation with this reference already existing - do nothing: #{existing_ref} - #{notification.inspect}"
          end

        end
        profile.save
        save
      end

      # credit a negative balance to the subscribers credit card
      # returns amount credited on success, false for failure, nil for nothing
      def credit_balance
        #debugger
        # nothing to credit?
        return if balance_cents >= 0
        # no cc on fle
        return false if profile.no_info? || profile.profile_key.nil?

        transaction do # makes this atomic
          #debugger
          # credit the card
          tx  = SubscriptionTransaction.credit( -balance_cents, profile.profile_key, :subscription => self )
          # save the transaction
          transactions.push( tx )
          # set profile state and reset balance
          if tx.success
            self.update_attribute :balance_cents, 0
            profile.authorized
          else
            profile.error
          end
          tx.success && tx.amount
        end
      end

      # true if account is due today or before
      def due?( days_from_now = 0)
        days_remaining && (days_remaining <= days_from_now)
      end

      # date trial ends, or nil if not eligable
      def trial_ends_on
        # no trials?
        return if SubscriptionConfig.trial_period.to_i==0
        case 
          # in trial, days remaining
          when trial?     :    next_renewal_on
          # new record? would start from today
          when plan.nil?  :    Time.zone.today + SubscriptionConfig.trial_period.days
          # start or continue a trial? prorate since creation
          #when active?    :
        else
          d = (created_at || Time.now).to_date + SubscriptionConfig.trial_period.days
          d unless d <= Time.zone.today
          # else nil not eligable
        end
      end

      # number of days until next renewal
      def days_remaining
        (next_renewal_on - Time.zone.today) unless next_renewal_on.nil?
      end

      # number of days account is past due (negative of days_remaining)
      def past_due_days
        (Time.zone.today - next_renewal_on) unless next_renewal_on.nil?
      end

      # number of days until account expires
      def grace_days_remaining
        (next_renewal_on + SubscriptionConfig.grace_period.days - Time.zone.today) if past_due?
      end

      # most recent transaction
      def latest_transaction
        transactions.first
      end

      protected

      def initialize_defaults
        # default plan
        self.plan ||= SubscriptionPlan.default_plan
        # bug fix: when aasm sometimes doesnt initialize
        self.state ||= 'pending'
      end

      def initialize_state_from_plan
        # build profile if not present
        self.create_profile if profile.nil?
        # initialize the state (and renewal date) [doing this after create since aasm saves]
        if plan.free?
          self.free
        elsif SubscriptionConfig.trial_period > 0
          self.trial
        else
          self.active
        end
      end
    end
  end
end