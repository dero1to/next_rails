# frozen_string_literal: true

require "spec_helper"

require "timecop"

RSpec.describe NextRails::GemInfo do
  let(:release_date) { Time.utc(2019, 7, 6, 0, 0, 0) }
  let(:now) { Time.utc(2019, 7, 6, 12, 0, 0) }
  let(:spec) do
    Gem::Specification.new do |s|
      s.date = release_date
      s.version = "1.0.0"
    end
  end

  subject { NextRails::GemInfo.new(spec) }

  describe "#age" do
    around do |example|
      Timecop.travel(now) do
        example.run
      end
    end

    let(:result) { release_date.strftime("%b %e, %Y") }

    it "returns a date when the local gemspec date is valid" do
      expect(subject.age).to eq(result)
    end

    context "when the local gemspec date is before year 2000 (e.g. Docker container reset timestamp)" do
      let(:invalid_date) { Time.utc(1980, 1, 2, 0, 0, 0) }
      let(:spec) do
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.date = invalid_date
          s.version = "1.0.0"
        end
      end

      context "and the RubyGems API returns a valid ISO8601 timestamp with milliseconds" do
        let(:api_created_at) { "2026-01-08T20:18:04.374Z" }

        before do
          stub_request(:get, "https://rubygems.org/api/v1/versions/mygem.json")
            .to_return(
              status: 200,
              body: JSON.generate([{ "number" => "1.0.0", "created_at" => api_created_at }]),
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "returns the date from the API" do
          expected = Time.iso8601(api_created_at).strftime("%b %e, %Y")
          expect(subject.age).to eq(expected)
        end
      end

      context "and the RubyGems API returns no matching version" do
        before do
          stub_request(:get, "https://rubygems.org/api/v1/versions/mygem.json")
            .to_return(
              status: 200,
              body: JSON.generate([{ "number" => "2.0.0", "created_at" => "2026-01-01T00:00:00.000Z" }]),
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "returns 'unknown'" do
          expect(subject.age).to eq("unknown")
        end
      end

      context "and the RubyGems API request fails" do
        before do
          stub_request(:get, "https://rubygems.org/api/v1/versions/mygem.json")
            .to_return(status: 500)
        end

        it "returns 'unknown'" do
          expect(subject.age).to eq("unknown")
        end
      end

      context "and the created_at field is missing from the API response" do
        before do
          stub_request(:get, "https://rubygems.org/api/v1/versions/mygem.json")
            .to_return(
              status: 200,
              body: JSON.generate([{ "number" => "1.0.0" }]),
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "returns 'unknown'" do
          expect(subject.age).to eq("unknown")
        end
      end
    end
  end

  describe "#created_at" do
    context "when the local gemspec date is valid (>= year 2000)" do
      it "returns the gemspec date without making an API call" do
        expect(subject.created_at).to eq(release_date)
        expect(WebMock).not_to have_requested(:get, /rubygems.org\/api\/v1\/versions/)
      end
    end

    context "when the local gemspec date is invalid (before year 2000)" do
      let(:invalid_date) { Time.utc(1980, 1, 2, 0, 0, 0) }
      let(:api_created_at) { "2026-01-08T20:18:04.374Z" }
      let(:spec) do
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.date = invalid_date
          s.version = "1.0.0"
        end
      end

      before do
        stub_request(:get, "https://rubygems.org/api/v1/versions/mygem.json")
          .to_return(
            status: 200,
            body: JSON.generate([{ "number" => "1.0.0", "created_at" => api_created_at }]),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "fetches the date from the RubyGems API" do
        expect(subject.created_at).to eq(Time.iso8601(api_created_at))
      end

      it "correctly parses ISO8601 timestamps with milliseconds and trailing Z" do
        result = subject.created_at
        expect(result).to be_a(Time)
        expect(result.utc.year).to eq(2026)
        expect(result.utc.month).to eq(1)
        expect(result.utc.day).to eq(8)
      end
    end

    context "when the API call fails" do
      let(:invalid_date) { Time.utc(1980, 1, 2, 0, 0, 0) }
      let(:spec) do
        Gem::Specification.new do |s|
          s.name = "mygem"
          s.date = invalid_date
          s.version = "1.0.0"
        end
      end

      before do
        stub_request(:get, "https://rubygems.org/api/v1/versions/mygem.json")
          .to_raise(StandardError)
      end

      it "returns nil" do
        expect(subject.created_at).to be_nil
      end
    end
  end

  describe "#up_to_date?" do
    it "is up to date" do
      allow(Gem).to receive(:latest_spec_for).and_return(spec)
      expect(subject.up_to_date?).to be_truthy
    end
  end

  describe "#state" do
    let(:mock_gem) { Struct.new(:name, :version, :runtime_dependencies) }
    let(:mocked_dependency) { Struct.new(:name, :requirement) }

    it "returns :incompatible if gem specifies a rails dependency but no compatible version is found" do
      # set up a mock gem with with a rails dependency that is unsatisfied by the version given
      mocked_dependency_requirement = double("requirement")
      allow(mocked_dependency_requirement).to receive(:satisfied_by?).and_return(false)
      runtime_deps = [mocked_dependency.new("rails", mocked_dependency_requirement)]
      incompatible_gem = mock_gem.new('incompatible', '0.0.1', runtime_deps)

      rails_version = "7.0.0"
      gem_info = NextRails::GemInfo.new(incompatible_gem)

      expect(gem_info.state(rails_version)).to eq(:incompatible)
    end

    it "returns :no_new_version if a gem specifies an unsatisfied rails dependency and no other specs are returned" do
      # set up a mock gem with with a rails dependency that is unsatisfied by the version given
      mocked_dependency_requirement = double("requirement")
      allow(mocked_dependency_requirement).to receive(:satisfied_by?).and_return(false)
      runtime_deps = [mocked_dependency.new("rails", mocked_dependency_requirement)]
      incompatible_gem = mock_gem.new('incompatible', '0.0.1', runtime_deps)

      # Set up a mock SpecFetcher to return an empty list
      fetcher_double = double("spec_fetcher")
      allow(fetcher_double).to receive(:available_specs).and_return([[],[]])
      allow(Gem::SpecFetcher).to receive(:new).and_return(fetcher_double)

      rails_version = "7.0.0"
      gem_info = NextRails::GemInfo.new(incompatible_gem)
      gem_info.find_latest_compatible

      expect(gem_info.state(rails_version)).to eq(:no_new_version)
    end
  end

  describe "#find_latest_compatible" do
    let(:mock_gem) { Struct.new(:name, :version) }

    it "sets latest_compatible_version to NullGem if no specs are found" do
      gem = mock_gem.new('gem_name', "0.0.1")

      # Set up a mock SpecFetcher to return an empty list
      fetcher_double = double("spec_fetcher")
      allow(fetcher_double).to receive(:available_specs).and_return([[],[]])
      allow(Gem::SpecFetcher).to receive(:fetcher).and_return(fetcher_double)

      gem_info = NextRails::GemInfo.new(gem)
      gem_info.find_latest_compatible
      expect(gem_info.latest_compatible_version).to be_a(NextRails::GemInfo::NullGemInfo)
    end
  end
end
