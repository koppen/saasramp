require File.dirname(__FILE__) + '/../spec_helper'
require File.dirname(__FILE__) + '/../acts_as_subscriber_spec'

class ParanoidUser < FakeUser
  def self.paranoid?
    true
  end
end

describe ParanoidUser, 'using acts_as_paranoid' do
  it "should define polymorphic subscription association without dependency" do
    ParanoidUser.should_receive(:has_one).with(:subscription, :as => :subscriber)
    ParanoidUser.send(:acts_as_subscriber)
  end
end

describe FakeUser, 'class' do
  it "should define polymorphic subscription association with dependency" do
    FakeUser.should_receive(:has_one).with(:subscription, :as => :subscriber, :dependent => :destroy)
    FakeUser.send(:acts_as_subscriber)
  end

  it "should validate the associated subscription" do
    FakeUser.should_receive(:validates_associated).with(:subscription)
    FakeUser.send(:acts_as_subscriber)
  end
end

describe FakeUser, 'instance' do
  let(:subscriber) { FakeUser.send(:acts_as_subscriber); FakeUser.new }
  let(:plan) { (plan = SubscriptionPlan.new(:name => 'Gold')).tap { plan.stub!(:save).and_return(true) } }
  let(:subscription) { (subscription = Subscription.new).tap { subscription.stub!(:save).and_return(true); subscription.stub!(:plan).and_return(plan) } }

  describe "setting the subscription_plan" do
    before :each do
      subscriber.stub!(:subscription).and_return(nil)
    end

    context "and plan is a SubscriptionPlan" do
      it "should set the @newplan instance variable" do
        subscriber.subscription_plan = plan
        subscriber.instance_variable_get('@newplan').should == plan
      end
    end

    context "and plan is given as an id string" do
      it "should find the plan by id" do
        SubscriptionPlan.should_receive(:find_by_id).with('1').and_return(plan)
        subscriber.subscription_plan = '1'
        subscriber.instance_variable_get('@newplan').should == plan
      end
    end

    context "and plan is given as a name string" do
      it "should find the plan by name" do
        SubscriptionPlan.should_receive(:find_by_name).with('Über').and_return(plan)
        subscriber.subscription_plan = 'Über'
        subscriber.instance_variable_get('@newplan').should == plan
      end
    end

    it "should not attempt to change the plan" do
      subscription.should_receive(:change_plan).never
      subscriber.subscription_plan = plan
    end

    context "when subscriber has a subscription" do
      before :each do
        subscriber.stub!(:subscription).and_return(subscription)
      end

      it "should change the plan" do
        subscription.should_receive(:change_plan).with(plan)
        subscriber.subscription_plan = plan
      end
    end
  end

  describe "getting the subscription_plan" do
    context "and subscriber does not have a subscription" do
      before :each do
        subscriber.stub!(:subscription).and_return(nil)
      end

      it "should return nil" do
        subscriber.subscription_plan.should be_nil
      end

      context "and the subscription plan has recently been set" do
        let(:some_other_plan) { SubscriptionPlan.new(:name => 'New plan') }

        it "should return the new plan" do
          subscriber.subscription_plan = some_other_plan
          subscriber.subscription_plan.should == some_other_plan
        end
      end
    end

    context "and subscriber does have a subscription" do
      before :each do
        subscriber.stub!(:subscription).and_return(subscription)
      end

      it "should return the plan from subscription" do
        subscription.stub!(:plan).and_return(subscription)
        subscriber.subscription_plan.should_not be_nil
        subscriber.subscription_plan.should == subscriber.subscription.plan
      end

      context "and the subscription plan has recently been set" do
        let(:some_other_plan) { SubscriptionPlan.new(:name => 'New plan') }

        it "should return the new plan" do
          subscriber.subscription_plan = some_other_plan
          subscriber.subscription_plan.should == some_other_plan
        end
      end
    end
  end
end
