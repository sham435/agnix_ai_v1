# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations

require "rails_helper"

RSpec.describe Llm::LocalModelGate do
  before { described_class.reset! }
  after  { described_class.reset! }

  it "recognizes only the local providers as needing serialization" do
    expect(described_class.local?("bonsai")).to be(true)
    expect(described_class.local?(:ollama)).to be(true)
    expect(described_class.local?("anthropic")).to be(false)
    expect(described_class.local?("openai")).to be(false)
  end

  it "never lets more than `slots` holders in at once" do
    gate = described_class.new(slots: 1, wait_timeout: 5)
    peak = 0
    current = 0
    lock = Mutex.new
    inside = Queue.new
    release = Queue.new

    holder = Thread.new do
      gate.acquire do
        lock.synchronize { current += 1; peak = [peak, current].max }
        inside << :in
        release.pop
        lock.synchronize { current -= 1 }
      end
    end

    inside.pop # the holder is genuinely inside the gate now

    waiter = Thread.new do
      gate.acquire do
        lock.synchronize { current += 1; peak = [peak, current].max; current -= 1 }
      end
    end

    sleep 0.1 # give the waiter a chance to (fail to) enter while it is held
    release << :go
    holder.join
    waiter.join

    expect(peak).to eq(1)
  end

  it "releases the slot even when the block raises" do
    gate = described_class.new(slots: 1, wait_timeout: 1)

    expect { gate.acquire { raise "boom" } }.to raise_error("boom")
    expect(gate.in_use).to eq(0)
    expect { gate.acquire { :ok } }.not_to raise_error
  end

  it "raises SlotTimeout rather than waiting forever behind a wedged holder" do
    gate = described_class.new(slots: 1, wait_timeout: 0.1)

    holder = Thread.new { gate.acquire { sleep 0.5 } }
    sleep 0.05 # let the holder take the slot first

    expect { gate.acquire { nil } }.to raise_error(described_class::SlotTimeout)
    holder.join
  end

  it "runs several acquisitions concurrently when slots allow it" do
    gate = described_class.new(slots: 2, wait_timeout: 5)
    both_in = Queue.new
    release = Queue.new

    threads = 2.times.map do
      Thread.new do
        gate.acquire do
          both_in << :in
          release.pop
        end
      end
    end

    2.times { both_in.pop } # both entered, so 2 slots really do run together
    expect(gate.in_use).to eq(2)

    2.times { release << :go }
    threads.each(&:join)
    expect(gate.in_use).to eq(0)
  end
end

# rubocop:enable RSpec/MultipleExpectations
