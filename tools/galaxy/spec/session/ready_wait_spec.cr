require "../spec_helper"

describe Galaxy::ReadyWait do
  it "reads the opening turn from session:input-ready" do
    result = Galaxy::ReadyWait.decide("session:input-ready", JSON.parse(%({"opening_event_id":18})))
    result.should eq(Galaxy::ReadyWait::Ready.new(18_i64))
  end

  it "treats a null or missing opening as a quiet start" do
    Galaxy::ReadyWait.decide("session:input-ready", JSON.parse(%({"opening_event_id":null})))
      .should eq(Galaxy::ReadyWait::Ready.new(nil))
    Galaxy::ReadyWait.decide("session:input-ready", nil).should eq(Galaxy::ReadyWait::Ready.new(nil))
  end

  it "names what it knows about an exit before the session was ready" do
    result = Galaxy::ReadyWait.decide("session:exited", JSON.parse(%({"exit_code":1,"initiated_by":"user"})))
    result.should eq(Galaxy::ReadyWait::NotReady.new(
      "the session exited before it was ready for input (exit code 1, stopped by user)", 1))
  end

  it "still fails an exit with no detail" do
    result = Galaxy::ReadyWait.decide("session:exited", JSON::Any.new(nil))
    result.should eq(Galaxy::ReadyWait::NotReady.new("the session exited before it was ready for input", 1))
  end
end
