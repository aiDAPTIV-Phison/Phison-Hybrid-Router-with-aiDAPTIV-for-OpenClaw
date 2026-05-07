import { afterEach, describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import {
  setHybridGatewayCompactionReserveTokens,
  setHybridGatewayEdgeMaxContextTokens,
} from "./hybrid-gateway-cloud-fallback.js";
import { resolvePayloadEscalationThreshold } from "./hybrid-gateway-stream-guard.js";
import { applyPiCompactionSettingsFromConfig } from "./pi-settings.js";

describe("applyPiCompactionSettingsFromConfig (hybrid-gateway reserve)", () => {
  afterEach(() => {
    setHybridGatewayCompactionReserveTokens(undefined);
    setHybridGatewayEdgeMaxContextTokens(undefined);
  });

  it("aligns Pi reserveTokens to edgeMax - escalationThresholdTokens when hybrid edgeMax is set", () => {
    const edgeMax = 18432;
    setHybridGatewayEdgeMaxContextTokens(edgeMax);
    setHybridGatewayCompactionReserveTokens(8192);
    const escalationThresholdTokens = resolvePayloadEscalationThreshold(edgeMax).escalationThresholdTokens;
    const alignedReserve = edgeMax - escalationThresholdTokens;

    const applyOverrides = vi.fn();
    const settingsManager = {
      getCompactionReserveTokens: () => 16_384,
      getCompactionKeepRecentTokens: () => 4096,
      applyOverrides,
    };
    const cfg = {
      agents: {
        defaults: {
          compaction: {
            reserveTokensFloor: 20_000,
          },
        },
      },
    } as OpenClawConfig;

    const result = applyPiCompactionSettingsFromConfig({ settingsManager, cfg });

    expect(result.compaction.reserveTokens).toBe(alignedReserve);
    expect(applyOverrides).toHaveBeenCalledWith({
      compaction: { reserveTokens: alignedReserve },
    });
  });

  it("falls back to routing.contextReserveTokens mirror when edgeMax is unset", () => {
    setHybridGatewayCompactionReserveTokens(8192);
    const applyOverrides = vi.fn();
    const settingsManager = {
      getCompactionReserveTokens: () => 16_384,
      getCompactionKeepRecentTokens: () => 4096,
      applyOverrides,
    };
    const cfg = {
      agents: {
        defaults: {
          compaction: {
            reserveTokensFloor: 20_000,
          },
        },
      },
    } as OpenClawConfig;

    const result = applyPiCompactionSettingsFromConfig({ settingsManager, cfg });

    expect(result.compaction.reserveTokens).toBe(8192);
    expect(applyOverrides).toHaveBeenCalledWith({
      compaction: { reserveTokens: 8192 },
    });
  });

  it("prefers explicit agents.defaults.compaction.reserveTokens over hybrid reserve", () => {
    setHybridGatewayCompactionReserveTokens(8192);
    const applyOverrides = vi.fn();
    const settingsManager = {
      getCompactionReserveTokens: () => 5000,
      getCompactionKeepRecentTokens: () => 4096,
      applyOverrides,
    };
    const cfg = {
      agents: {
        defaults: {
          compaction: {
            reserveTokens: 10_000,
            reserveTokensFloor: 5000,
          },
        },
      },
    } as OpenClawConfig;

    const result = applyPiCompactionSettingsFromConfig({ settingsManager, cfg });

    expect(result.compaction.reserveTokens).toBe(10_000);
    expect(applyOverrides).toHaveBeenCalledWith({
      compaction: { reserveTokens: 10_000 },
    });
  });
});
