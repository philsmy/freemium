# == Attributes
#   subscribable:         the model in your system that has the subscription. probably a User.
#   subscription_plan:    which service plan this subscription is for. affects how payment is interpreted.
#   paid_through:         when the subscription currently expires, assuming no further payment. for manual billing, this also determines when the next payment is due.
#   billing_key:          the id for this user in the remote billing gateway. may not exist if user is on a free plan.
#   last_transaction_at:  when the last gateway transaction was for this account. this is used by your gateway to find "new" transactions.
#
class Subscription < ActiveRecord::Base
  belongs_to :subscription_plan
  belongs_to :subscribable, :polymorphic => true

  before_validation :set_paid_through

  validates_presence_of :subscribable
  validates_presence_of :subscription_plan
  validates_presence_of :paid_through

  # receives payment and saves the record
  def receive_payment!(value)
    receive_payment(value)
    save!
  end

  # sets the expiration for the subscription based on today and the configured grace period.
  def expire_after_grace!
    self.expire_on = [Date.today, paid_through].max + Freemium.days_grace
    Freemium.mailer.deliver_expiration_warning(subscribable, self)
    save!
  end

  # sends an invoice for the specified amount. note that this is an after-the-fact
  # invoice.
  def send_invoice(amount)
    Freemium.mailer.deliver_invoice(subscribable, self, amount)
  end

  # returns the value of the time between now and paid_through.
  # will optionally interpret the time according to a certain subscription plan.
  def remaining_value(subscription_plan_id = self.subscription_plan_id)
    SubscriptionPlan.find(subscription_plan_id).daily_rate * remaining_days
  end

  # if paid through today, returns zero
  def remaining_days
    self.paid_through - Date.today
  end

  # if under grace through today, returns zero
  def remaining_days_of_grace
    self.expire_on - Date.today - 1
  end

  def in_grace?
    remaining_days < 0 and expire_on > Date.today
  end

  def expired?
    remaining_days < 0 and expire_on >= paid_through and expire_on <= Date.today
  end

  # expires all subscriptions that have been pastdue for too long (accounting for grace)
  def self.expire
    find(:all, :conditions => ['expire_on >= paid_through AND expire_on <= ?', Date.today]).each(&:expire!)
  end

  # sends an expiration email, then downgrades to a free plan (if available) or disassociates the plan altogether
  def expire!
    Freemium.mailer.deliver_expiration_notice(subscribable, self)
    self.subscription_plan = SubscriptionPlan.find(:first, :conditions => ['rate_cents = 0'])
    self.save
  end

  protected

  # extends the paid_through period according to how much money was received.
  # when possible, avoids the days-per-month problem by checking if the money
  # received is a multiple of the plan's rate.
  #
  # really, i expect the case where the received payment does not match the
  # subscription plan's rate to be very much an edge case.
  def receive_payment(value)
    self.paid_through = if value.cents % subscription_plan.rate.cents == 0
      months_per_multiple = subscription_plan.yearly? ? 12 : 1
      self.paid_through >> months_per_multiple * value.cents / subscription_plan.rate.cents
    else
      # edge case
      self.paid_through + (value.cents / subscription_plan.daily_rate.cents)
    end

    send_invoice(value)
  end

  def set_paid_through
    self.paid_through ||= Date.today
  end
end