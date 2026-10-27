require "rails_helper"

RSpec.describe SafeMath do
  describe ".eval" do
    context "basic arithmetic" do
      it "adds integers" do
        expect(described_class.eval("2 + 3")).to eq(5.0)
      end

      it "subtracts integers" do
        expect(described_class.eval("10 - 4")).to eq(6.0)
      end

      it "multiplies" do
        expect(described_class.eval("3 * 7")).to eq(21.0)
      end

      it "divides" do
        expect(described_class.eval("10 / 3")).to be_within(0.0001).of(3.3333)
      end

      it "handles modulo" do
        expect(described_class.eval("10 % 3")).to eq(1.0)
      end
    end

    context "parentheses and precedence" do
      it "respects parentheses" do
        expect(described_class.eval("3 * (2 + 4.5)")).to eq(19.5)
      end

      it "respects multiplication before addition" do
        expect(described_class.eval("2 + 3 * 4")).to eq(14.0)
      end

      it "handles nested parentheses" do
        expect(described_class.eval("(2 + 3) * (4 - 1)")).to eq(15.0)
      end
    end

    context "unary operators" do
      it "handles leading negative" do
        expect(described_class.eval("-3 + 2")).to eq(-1.0)
      end

      it "handles unary plus" do
        expect(described_class.eval("-3 + +2")).to eq(-1.0)
      end

      it "handles unary minus in parentheses" do
        expect(described_class.eval("(-5) * 2")).to eq(-10.0)
      end

      it "handles double unary" do
        expect(described_class.eval("--3")).to eq(3.0)
      end
    end

    context "decimals" do
      it "handles decimal numbers" do
        expect(described_class.eval("1.5 + 2.5")).to eq(4.0)
      end

      it "handles leading dot" do
        expect(described_class.eval(".5 + .5")).to eq(1.0)
      end
    end

    context "error cases" do
      it "rejects empty input" do
        expect { described_class.eval("") }.to raise_error(SafeMath::Error, "Empty expression")
      end

      it "rejects non-math characters" do
        expect { described_class.eval("puts 'hello'") }.to raise_error(SafeMath::Error)
      end

      it "rejects variables" do
        expect { described_class.eval("2 + x") }.to raise_error(SafeMath::Error)
      end

      it "rejects method calls" do
        expect { described_class.eval("2.abs") }.to raise_error(SafeMath::Error)
      end

      it "rejects trailing input" do
        expect { described_class.eval("2+2abc") }.to raise_error(SafeMath::Error)
      end

      it "raises on division by zero" do
        expect { described_class.eval("1 / 0") }.to raise_error(SafeMath::Error, "Division by zero")
      end

      it "raises on mismatched parentheses" do
        expect { described_class.eval("(2 + 3") }.to raise_error(SafeMath::Error, "Missing closing parenthesis")
      end
    end

    context "whitespace handling" do
      it "ignores extra whitespace" do
        expect(described_class.eval("  2   +   3  ")).to eq(5.0)
      end

      it "handles no whitespace" do
        expect(described_class.eval("2+3*4")).to eq(14.0)
      end
    end
  end
end
