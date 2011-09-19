namespace :saas do
  
  desc "Seeds or updates the subscription_plans table data from db/subscription_plans.yml. Note, if plan name exists it will be updated with any new values. For production db run with RAILS_ENV=production"
  task :plans => :environment do
    file = RAILS_ROOT + '/db/subscription_plans.yml'
    if ! File.exists?(file)
      puts "#{file} not found."
      return
    end
    base_name = File.basename(file, '.*')
    puts "Loading #{base_name}..."
    raw = File.read(file)
    data = YAML.load(raw)[RAILS_ENV].symbolize_keys
    data[:plans].each do |params|
      params.symbolize_keys!
      if plan = SubscriptionPlan.find_by_name( params[:name] )
        # update existing
        plan.attributes = params
        if plan.changed?
          if plan.save
            puts "updated '#{params[:name]}'"
          else
            puts "error updating '#{params[:name]}'"
            puts plan.errors.full_messages.inspect
          end
        else
          puts "no changes to '#{params[:name]}'"
        end
      else
        # create new
        plan = SubscriptionPlan.create( params )
        if plan.new_record?
          puts "error creating '#{params[:name]}'"
          puts plan.errors.full_messages.inspect
        else
          puts "created '#{params[:name]}'"
        end
      end  
    end  
  end
  
  desc "Daily subscription processing, including renewals and email messages"
  task :daily => :environment do
    def logger
      Rails.logger
    end

    Lockfile('subscription_daily_lock', :retries => 0) do
      logger.info { "SaasRamp: Starting daily subscription processing" }

      # send warnings that trial ending in 3 days
      Subscription.with_state(:trial).with_no_warnings.due_in(3.days).each do |sub|
        logger.info { "SaasRamp: Send trial expiring #{sub.inspect}"}
        SubscriptionConfig.mailer.deliver_trial_expiring(sub)
        sub.increment!(:warning_level)
      end
      
      # renew subscriptions that are due now
      Subscription.with_states(:trial, :active).due_now.each do |sub| 
        if sub.renew
          logger.info { "SaasRamp: Renewed #{sub.inspect}"}
        else
          logger.info { "SaasRamp: Couldn't renew #{sub.inspect}"}

          # Make sure we send out second_charge_failure in 3 days time
          sub.update_attribute(:warning_level, 1)
        end
      end

      # try past due after a couple days
      Subscription.with_state(:past_due).with_warning_level(1).due_ago(3.days).each do |sub| 
        logger.info { "SaasRamp: Renewing subscription #{sub.inspect}" }
        sub.renew 
      end

      # end of grace period, try again or expire the subscription
      Subscription.with_state(:past_due).due_ago(SubscriptionConfig.grace_period.days).each  do |sub| 
        if sub.renew
          logger.info { "SaasRamp: Renewed past_due subscription at end of grace period #{sub.inspect}" }
        else
          logger.info { "SaasRamp: Expiring #{sub.inspect}" }
          # expired subscriptions change to a free plan and change state to 'expired'
          # (your app may also do other things on expire)
          sub.expired
        end
      end
      
    end
  end
end
