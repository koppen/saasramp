# acts_as_subscriber
module Saasramp           #:nodoc:
  module Acts                 #:nodoc:
    module Subscriber         #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end
      
      module ClassMethods
        def acts_as_subscriber(options = {})
          # when subscriber is using acts_as_paranoid, we'll destroy subscription (and its children) only when really really destroyed
          if self.respond_to?(:paranoid?) && self.paranoid?
            has_one :subscription, :as => :subscriber
          else
            has_one :subscription, :as => :subscriber, :dependent => :destroy
          end
          validates_associated :subscription

          include Saasramp::Acts::Subscriber::InstanceMethods
          extend Saasramp::Acts::Subscriber::SingletonMethods
        end
      end
      
      module SingletonMethods
      end
      
      module InstanceMethods
        # delegate for easier user forms
        # for example, to sign up params[:user] => { :username => 'foo', :subscription_plan => '2', etc. }
        attr_accessor :subscription_plan
        
  		  def subscription_plan=(plan)
 		      # arg can be object or id or name
 		      @newplan = case
 		        when plan.is_a?(SubscriptionPlan):  plan 
 		        when plan.to_i > 0:                 SubscriptionPlan.find_by_id(plan)
 		        else                                SubscriptionPlan.find_by_name(plan)
 		      end

          if subscription.nil?
            # Make sure we have a subscription. The actual changing plan to @newplan is handled in
            # after_save, because changing the plan causes AASM to save the record, and it's a bit
            # premature to save here.
            self.build_subscription
          else
            # not just change the attribute, really switch plans
            subscription.change_plan @newplan
          end

          return subscription_plan
  			end

        def subscription_plan
          return @newplan if @newplan
          subscription.plan if subscription
        end

  		  # overwrite this method
  		  # compare subscriber to the plan's limits
  		  # return a blank value if ok (nil, false, [], {}), anything else means subscriber has exceeded limits
  		  # maybe should make this a callback option to acts_as_subscriber
  		  def subscription_plan_check(plan)
  		    # example:
          # exceeded = {}
          # exceeded[:memory_used] = plan.max_memory if subscriber.memory_used > plan.max_memory
          # exceeded[:file_count]  = plan.max_files  if subscriber.file_count > plan.max_files
          # exceeded
		    end

		    # when acts_as_paranoid, only destroy dependents when i'm really getting destroyed
		    # (this way we don't have to also make the dependents acts_as_paranoid)
		    def destroy!
		      self.subscription.destroy if self.class.respond_to?(:paranoid?) && self.class.paranoid? && self.subscription
		      super
	      end
  		  
        protected
        
        def after_save
          # this is the best time to create the subscription
          # because cannot build_subscription while self.id is still nil
          self.create_subscription if subscription.nil?
          self.subscription.change_plan @newplan if @newplan
        end
      end
      
    end
  end
end

ActiveRecord::Base::send(:include, Saasramp::Acts::Subscriber)
