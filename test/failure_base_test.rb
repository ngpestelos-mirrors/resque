require 'test_helper'
require 'minitest/mock'

require 'resque/failure/base'

class TestFailure < Resque::Failure::Base
end

# The shape third-party backends ship: four positional arguments, bare super.
class ThirdPartyFailure < Resque::Failure::Base
  class << self
    attr_accessor :last_saved
  end

  def initialize(exception, worker, queue, payload)
    super
  end

  def save
    self.class.last_saved = self
  end
end

class BackendWithoutBase
  class << self
    attr_accessor :saved
  end

  def initialize(exception, worker, queue, payload)
  end

  def save
    self.class.saved = true
  end
end

describe "Base failure class" do
  let(:exception) { StandardError.exception('some error') }
  let(:worker)    { Resque::Worker.new(:test) }
  let(:queue)     { 'queue' }
  let(:payload)   { { 'class' => 'Object', 'args' => 3 } }

  it "allows calling all without throwing" do
    with_failure_backend TestFailure do
      assert_empty Resque::Failure.all
    end
  end

  it "takes four positional arguments" do
    assert_equal 4, Resque::Failure::Base.instance_method(:initialize).arity
  end

  it "generates a failure_id when it is built" do
    failure = TestFailure.new(exception, worker, queue, payload)
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, failure.failure_id)
  end

  it "gives each failure its own failure_id" do
    first  = TestFailure.new(exception, worker, queue, payload)
    second = TestFailure.new(exception, worker, queue, payload)
    refute_equal first.failure_id, second.failure_id
  end

  it "accepts an assigned failure_id" do
    failure = TestFailure.new(exception, worker, queue, payload)
    failure.failure_id = 'assigned-id'
    assert_equal 'assigned-id', failure.failure_id
  end

  it "has no failure_id when generation is disabled" do
    failure = with_failure_id_generation false do
      TestFailure.new(exception, worker, queue, payload)
    end

    assert_nil failure.failure_id
  end

  it "assigns a failure_id to backends created through Resque::Failure.create" do
    with_failure_backend ThirdPartyFailure do
      Resque::Failure.create(:exception => exception, :worker => worker,
                             :queue => queue, :payload => payload)
    end

    saved = ThirdPartyFailure.last_saved
    refute_nil saved.failure_id
    assert_equal payload, saved.payload
  end

  it "honours a caller supplied failure_id" do
    with_failure_backend ThirdPartyFailure do
      Resque::Failure.create(:exception => exception, :worker => worker,
                             :queue => queue, :payload => payload,
                             :failure_id => 'caller-supplied-id')
    end

    assert_equal 'caller-supplied-id', ThirdPartyFailure.last_saved.failure_id
  end

  it "creates failures on backends that do not subclass Base" do
    with_failure_backend BackendWithoutBase do
      Resque::Failure.create(:exception => exception, :worker => worker,
                             :queue => queue, :payload => payload)
    end

    assert BackendWithoutBase.saved
  end

  it "does not assign a failure_id when generation is disabled" do
    with_failure_id_generation false do
      with_failure_backend ThirdPartyFailure do
        Resque::Failure.create(:exception => exception, :worker => worker,
                               :queue => queue, :payload => payload)
      end
    end

    assert_nil ThirdPartyFailure.last_saved.failure_id
  end

  it "honours a caller supplied failure_id when generation is disabled" do
    with_failure_id_generation false do
      with_failure_backend ThirdPartyFailure do
        Resque::Failure.create(:exception => exception, :worker => worker,
                               :queue => queue, :payload => payload,
                               :failure_id => 'caller-supplied-id')
      end
    end

    assert_equal 'caller-supplied-id', ThirdPartyFailure.last_saved.failure_id
  end
end
