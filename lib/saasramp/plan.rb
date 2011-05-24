module Saasramp
  module Plan
    def self.included(base)
      base.has_many :subscriptions

      base.composed_of :rate, :class_name => 'Money',
        :mapping => [%w(rate_cents cents), %w(currency currency_as_string)],
        :constructor => Proc.new { |cents, currency| Money.new(cents || 0, currency || SubscriptionConfig.currency) }

      base.validates_presence_of :name
      base.validates_uniqueness_of :name
      base.validates_presence_of :rate_cents
      base.validates_numericality_of :interval # in months

      base.send(:extend, ClassMethods)
      base.send(:include, InstanceMethods)
    end

    module ClassMethods
      def default_plan
        default_plan = SubscriptionPlan.find_by_name(SubscriptionConfig.default_plan) if SubscriptionConfig.respond_to? :default_plan
        default_plan ||= SubscriptionPlan.first( :conditions => { :rate_cents => 0 })
        default_plan ||= SubscriptionPlan.create( :name => 'free' ) #bootstrapper and tests
      end
    end

    module InstanceMethods
      def free?
        rate.zero?
      end

      def prorated_value( days )
        days ||= 0 # just in case called with nil
        # this calculation is a little off, we're going to assume 30 days/month rather than varying it month to month
        total_days = interval * 30
        daily_rate = rate_cents.to_f / total_days
        # round down to penny
        Money.new([(days * daily_rate).to_i, rate_cents].min, SubscriptionConfig.currency)
      end

      def to_s
        name
      end
    end
  end
end
