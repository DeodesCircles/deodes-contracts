// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeodesReputationRegistry} from "../src/DeodesReputationRegistry.sol";

/// @notice Reputation test suite (UNIFIED-PLAN 1.6). Every numbered case below
///         mirrors test/vectors/reputation-vectors.json EXACTLY — same inputs,
///         same expected numbers. Backend 2.9 must assert the same file.
contract DeodesReputationTest is Test {
    using stdJson for string;

    DeodesReputationRegistry internal reg;
    address internal user = makeAddr("user");

    function setUp() public {
        reg = new DeodesReputationRegistry();
        reg.setRecorder(address(this), true); // test acts as circle/factory
    }

    // ── access control ─────────────────────────────────────────────────────

    function test_NonRecorderCannotWrite() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DeodesReputationRegistry.NotRecorder.selector);
        reg.recordContribution(user, 10 ether, true);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DeodesReputationRegistry.NotRecorder.selector);
        reg.recordCompletion(user);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DeodesReputationRegistry.NotRecorder.selector);
        reg.recordDefault(user);
    }

    function test_SetRecorderOnlyOwner() public {
        address rec = makeAddr("recorder");
        vm.prank(user);
        vm.expectRevert(DeodesReputationRegistry.NotOwner.selector);
        reg.setRecorder(rec, true);
        reg.setRecorder(rec, true);
        assertTrue(reg.isRecorder(rec));
        reg.setRecorder(rec, false);
        assertFalse(reg.isRecorder(rec));
    }

    // ── vectors V1–V3: fresh / single / double ─────────────────────────────

    function test_V1FreshUserZero() public view {
        assertEq(reg.streakScore(user), 0);
        assertEq(reg.completionScore(user), 0);
        assertEq(reg.volumeScore(user), 0);
        assertEq(reg.recencyScore(user), 0);
        assertEq(reg.scoreOf(user), 0);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Bronze));
    }

    function test_V2SingleOnTime195Bronze() public {
        reg.recordContribution(user, 10 ether, true);
        assertEq(reg.streakScore(user), 35);
        assertEq(reg.volumeScore(user), 10);
        assertEq(reg.recencyScore(user), 150);
        assertEq(reg.scoreOf(user), 195);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Bronze));
    }

    function test_V3TwoOnTime240Silver() public {
        reg.recordContribution(user, 10 ether, true);
        reg.recordContribution(user, 10 ether, true);
        assertEq(reg.streakScore(user), 70);
        assertEq(reg.volumeScore(user), 20);
        assertEq(reg.scoreOf(user), 240);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Silver));
    }

    // ── vectors V4–V6: saturation / late / default ─────────────────────────

    function test_V4SaturatedDiamond1000() public {
        for (uint256 i = 0; i < 10; i++) {
            reg.recordContribution(user, 25 ether, true);
        }
        for (uint256 i = 0; i < 6; i++) {
            reg.recordCompletion(user);
        }
        assertEq(reg.streakScore(user), 350, "streak capped");
        assertEq(reg.completionScore(user), 300, "completions capped");
        assertEq(reg.volumeScore(user), 200, "volume capped at 200 USDC");
        assertEq(reg.recencyScore(user), 150);
        assertEq(reg.scoreOf(user), 1000);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Diamond));
    }

    function test_V5LateResetsStreak190Bronze() public {
        for (uint256 i = 0; i < 3; i++) {
            reg.recordContribution(user, 10 ether, true);
        }
        reg.recordContribution(user, 10 ether, false);
        assertEq(reg.streakScore(user), 0, "late resets streak");
        assertEq(reg.volumeScore(user), 40, "volume still accumulates");
        assertEq(reg.scoreOf(user), 190);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Bronze));
    }

    function test_V6DefaultResetsAndCounts200Silver() public {
        for (uint256 i = 0; i < 5; i++) {
            reg.recordContribution(user, 10 ether, true);
        }
        reg.recordDefault(user);
        assertEq(reg.streakScore(user), 0);
        assertEq(reg.scoreOf(user), 200, "0 + 0 + 50 + 150");
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Silver));
        assertEq(reg.recordOf(user).defaults, 1);
    }

    // ── vectors V7–V8: recency decay ───────────────────────────────────────

    function test_V7Stale100Days500Gold() public {
        for (uint256 i = 0; i < 10; i++) {
            reg.recordContribution(user, 10 ether, true);
        }
        vm.warp(block.timestamp + 100 days);
        assertEq(reg.recencyScore(user), 50);
        assertEq(reg.scoreOf(user), 500);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Gold));
    }

    function test_V8Dormant200Days450Gold() public {
        for (uint256 i = 0; i < 10; i++) {
            reg.recordContribution(user, 10 ether, true);
        }
        vm.warp(block.timestamp + 200 days);
        assertEq(reg.recencyScore(user), 0);
        assertEq(reg.scoreOf(user), 450);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Gold));
    }

    function test_RecencyTiersExact() public {
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        reg.recordContribution(user, 10 ether, true);
        vm.warp(t0 + 30 days);
        assertEq(reg.recencyScore(user), 150, "30d boundary inclusive");
        vm.warp(t0 + 30 days + 1);
        assertEq(reg.recencyScore(user), 100, "past 30d");
        vm.warp(t0 + 90 days);
        assertEq(reg.recencyScore(user), 100, "90d boundary inclusive");
        vm.warp(t0 + 90 days + 1);
        assertEq(reg.recencyScore(user), 50, "past 90d");
        vm.warp(t0 + 180 days);
        assertEq(reg.recencyScore(user), 50, "180d boundary inclusive");
        vm.warp(t0 + 180 days + 1);
        assertEq(reg.recencyScore(user), 0, "past 180d");
    }

    // ── vectors V9–V12 ─────────────────────────────────────────────────────

    function test_V9CompletionsOnly300Silver() public {
        for (uint256 i = 0; i < 6; i++) {
            reg.recordCompletion(user);
        }
        assertEq(reg.completionScore(user), 300);
        assertEq(reg.recencyScore(user), 0, "never active");
        assertEq(reg.scoreOf(user), 300);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Silver));
    }

    function test_V10WhaleCapped385Silver() public {
        reg.recordContribution(user, 500 ether, true);
        assertEq(reg.volumeScore(user), 200, "capped");
        assertEq(reg.scoreOf(user), 385);
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Silver));
    }

    function test_V12ExactGoldFloor400() public {
        for (uint256 i = 0; i < 5; i++) {
            reg.recordContribution(user, 5 ether, true);
        }
        reg.recordCompletion(user);
        assertEq(reg.scoreOf(user), 400, "175 + 50 + 25 + 150");
        assertEq(uint256(reg.tierOf(user)), uint256(DeodesReputationRegistry.Tier.Gold));
    }

    // ── tier table (vectors tiers) ─────────────────────────────────────────

    function test_TierTableExact() public view {
        DeodesReputationRegistry.Tier[5] memory tiers = [
            DeodesReputationRegistry.Tier.Bronze,
            DeodesReputationRegistry.Tier.Silver,
            DeodesReputationRegistry.Tier.Gold,
            DeodesReputationRegistry.Tier.Platinum,
            DeodesReputationRegistry.Tier.Diamond
        ];
        uint256[5] memory bips = [uint256(1000), 500, 300, 100, 0];
        uint256[5] memory sizes = [uint256(5), 10, 20, 50, 100];
        uint256[5] memory contribs = [uint256(100), 500, 2000, 10000, 50000];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(reg.collateralBips(tiers[i]), bips[i], "collateral bips");
            assertEq(reg.maxCircleSize(tiers[i]), sizes[i], "max size");
            assertEq(reg.maxContribution(tiers[i]), contribs[i], "max contribution");
        }
    }

    // ── eligibility hook (vectors eligibility) ─────────────────────────────

    function test_EligibilityBronzeAndDiamond() public {
        // Fresh user is Bronze.
        (bool ok, uint8 code) = reg.checkEligibility(user, 5, 100);
        assertTrue(ok);
        assertEq(code, reg.ELIGIBLE());
        (ok, code) = reg.checkEligibility(user, 6, 100);
        assertFalse(ok);
        assertEq(code, reg.SIZE_EXCEEDS_TIER());
        (ok, code) = reg.checkEligibility(user, 5, 101);
        assertFalse(ok);
        assertEq(code, reg.CONTRIBUTION_EXCEEDS_TIER());

        // Saturated Diamond (V4 setup).
        address whale = makeAddr("whale");
        for (uint256 i = 0; i < 10; i++) {
            reg.recordContribution(whale, 25 ether, true);
        }
        for (uint256 i = 0; i < 6; i++) {
            reg.recordCompletion(whale);
        }
        (ok, code) = reg.checkEligibility(whale, 100, 50_000);
        assertTrue(ok);
        assertEq(code, reg.ELIGIBLE());
        (ok, code) = reg.checkEligibility(whale, 101, 1);
        assertFalse(ok);
        assertEq(code, reg.SIZE_EXCEEDS_TIER());
    }

    // ── vectors file consistency (machine-checked, not eyeballed) ──────────

    /// @dev Guards JSON↔contract drift on the most copy-paste-prone part (the
    ///      tier table): parses test/vectors/reputation-vectors.json with
    ///      stdJson and asserts the on-chain getters match. Scenario cases
    ///      (V1–V12) are mirrored 1:1 as unit tests above; the JSON remains
    ///      the source of truth the backend 2.9 mirror ports.
    function test_VectorsFileMatchesTierTable() public view {
        string memory json =
            vm.readFile("test/vectors/reputation-vectors.json");
        string[5] memory names = ["Bronze", "Silver", "Gold", "Platinum", "Diamond"];
        DeodesReputationRegistry.Tier[5] memory tiers = [
            DeodesReputationRegistry.Tier.Bronze,
            DeodesReputationRegistry.Tier.Silver,
            DeodesReputationRegistry.Tier.Gold,
            DeodesReputationRegistry.Tier.Platinum,
            DeodesReputationRegistry.Tier.Diamond
        ];
        for (uint256 i = 0; i < 5; i++) {
            string memory base = string.concat(".tiers.", names[i], ".");
            assertEq(
                reg.collateralBips(tiers[i]),
                json.readUint(string.concat(base, "collateralBips")),
                "collateralBips drift"
            );
            assertEq(
                reg.maxCircleSize(tiers[i]),
                json.readUint(string.concat(base, "maxSize")),
                "maxSize drift"
            );
            assertEq(
                reg.maxContribution(tiers[i]),
                json.readUint(string.concat(base, "maxContributionUSDC")),
                "maxContribution drift"
            );
        }
        // Spot-check one scenario expectation end-to-end from the file.
        assertEq(json.readUint(".cases[3].expect.score"), 1000, "V4 Diamond vector");
        assertEq(json.readUint(".cases[5].expect.score"), 200, "V6 floor vector");
    }

    // ── fuzz: score always bounded ─────────────────────────────────────────

    function testFuzz_ScoreBounded(uint8 onTimes, uint8 lates, uint8 completions, uint8 defaults_) public {
        onTimes = uint8(bound(onTimes, 0, 30));
        lates = uint8(bound(lates, 0, 10));
        completions = uint8(bound(completions, 0, 20));
        defaults_ = uint8(bound(defaults_, 0, 10));
        for (uint256 i = 0; i < onTimes; i++) {
            reg.recordContribution(user, 10 ether, true);
        }
        for (uint256 i = 0; i < lates; i++) {
            reg.recordContribution(user, 10 ether, false);
        }
        for (uint256 i = 0; i < completions; i++) {
            reg.recordCompletion(user);
        }
        for (uint256 i = 0; i < defaults_; i++) {
            reg.recordDefault(user);
        }
        uint256 score = reg.scoreOf(user);
        assertLe(score, 1000, "never exceeds max");
        // Components individually capped.
        assertLe(reg.streakScore(user), 350);
        assertLe(reg.completionScore(user), 300);
        assertLe(reg.volumeScore(user), 200);
        assertLe(reg.recencyScore(user), 150);
        // Tier consistent with score.
        DeodesReputationRegistry.Tier tier = reg.tierOf(user);
        if (score >= 800) assertEq(uint256(tier), 4);
        else if (score >= 600) assertEq(uint256(tier), 3);
        else if (score >= 400) assertEq(uint256(tier), 2);
        else if (score >= 200) assertEq(uint256(tier), 1);
        else assertEq(uint256(tier), 0);
    }
}
