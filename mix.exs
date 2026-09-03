defmodule Managoat.Sandbox.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/managoat/managoat_sandbox"

  def project do
    [
      app: :managoat_sandbox,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "One sandbox behaviour over Sprites, E2B and Daytona, with the conformance suite a fourth adapter runs against.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [
        # This repository owns coverage for every shipped adapter. Provider
        # HTTP and streaming paths run against deterministic stubs; live
        # credentialed smoke tests remain a host-application concern.
        summary: [threshold: 85],
        # The conformance case is macros: its bodies run at test-compile time,
        # before cover instruments anything, so it always reports 0%. It is
        # exercised by fake_conformance_test.exs (and by every adapter's
        # conformance run) rather than measured.
        ignore_modules: [~r/^Managoat\.Sandbox\.ConformanceCase/]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Tooling for the repository, not the package: docs for hexdocs.pm (built
      # by `mix hex.publish`), credo and dialyzer for CI. dialyxir is pinned to
      # the commit that added OTP 28 support; 1.4.7 crashes on OTP 28 warnings.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir,
       github: "jeremyjh/dialyxir",
       ref: "3553678f4d69281ac6db61034bcf35bcb30cfd78",
       only: [:dev, :test],
       runtime: false},
      # The hex release, pinned exactly, because this SDK has already shipped
      # a contract change in a patch release: 0.2.2 made a stream that closes
      # without an exit frame `{:error, _, :closed_before_exit}` where 0.2.0
      # synthesised `{:exit, _, 0}`. `Managoat.Sandbox` now says the same
      # thing, so the pin is current rather than held back — but the reason
      # the range is exact stands. Widening it to `~> 0.2` would let the next
      # such change in silently; `sprites/protocol_contract_test.exs` guards
      # the two frame semantics we depend on, and a bump runs it first.
      {:sprites, "0.2.2"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      # Test / dev
      {:mimic, "~> 2.3", only: :test},
      # Req.Test and the Plug.Conn helpers the adapter tests stub with.
      {:plug, "~> 1.16", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp dialyzer do
    [
      ignore_warnings: ".dialyzer_ignore.exs",
      # A fixed path so CI can cache the PLT across runs.
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
