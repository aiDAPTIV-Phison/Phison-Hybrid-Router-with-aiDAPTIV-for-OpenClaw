import { afterEach, describe, expect, it } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { resolveContextWindowInfo } from "./context-window-guard.js";
import { setHybridGatewayEdgeMaxContextTokens } from "./hybrid-gateway-cloud-fallback.js";

describe("resolveContextWindowInfo (hybrid-gateway edge cap)", () => {
  afterEach(() => {
    setHybridGatewayEdgeMaxContextTokens(undefined);
  });

  it("caps to hybridGatewayEdge when edge max is lower than the model context window", () => {
    setHybridGatewayEdgeMaxContextTokens(16_384);
    const info = resolveContextWindowInfo({
      cfg: undefined,
      provider: "openrouter",
      modelId: "x",
      modelContextWindow: 128_000,
      defaultTokens: 100_000,
    });
    expect(info).toEqual({ tokens: 16_384, source: "hybridGatewayEdge" });
  });

  it("does not cap when hybrid gateway edge max is not set", () => {
    const info = resolveContextWindowInfo({
      cfg: undefined,
      provider: "openrouter",
      modelId: "x",
      modelContextWindow: 128_000,
      defaultTokens: 100_000,
    });
    expect(info.source).toBe("model");
    expect(info.tokens).toBe(128_000);
  });

  it("uses the smaller of agents.defaults.contextTokens and edge max", () => {
    setHybridGatewayEdgeMaxContextTokens(16_384);
    const cfg = {
      agents: { defaults: { contextTokens: 8192 } },
    } as OpenClawConfig;
    const info = resolveContextWindowInfo({
      cfg,
      provider: "openrouter",
      modelId: "x",
      modelContextWindow: 128_000,
      defaultTokens: 100_000,
    });
    expect(info.tokens).toBe(8192);
    expect(info.source).toBe("agentContextTokens");
  });

  it("applies hybridGatewayEdge when edge max is below the agent context cap", () => {
    setHybridGatewayEdgeMaxContextTokens(8000);
    const cfg = {
      agents: { defaults: { contextTokens: 16_384 } },
    } as OpenClawConfig;
    const info = resolveContextWindowInfo({
      cfg,
      provider: "openrouter",
      modelId: "x",
      modelContextWindow: 128_000,
      defaultTokens: 100_000,
    });
    expect(info.tokens).toBe(8000);
    expect(info.source).toBe("hybridGatewayEdge");
  });
});
