//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";
import {OwnableStorage} from "@synthetixio/core-contracts/contracts/ownership/OwnableStorage.sol";
import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {SafeCastU256, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {PerpMarketConfiguration} from "../storage/PerpMarketConfiguration.sol";
import {PerpMarket} from "../storage/PerpMarket.sol";
import {Margin} from "../storage/Margin.sol";
import {Order} from "../storage/Order.sol";
import {Position} from "../storage/Position.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {ErrorUtil} from "../utils/ErrorUtil.sol";
import "../interfaces/IMarginModule.sol";

contract MarginModule is IMarginModule {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using PerpMarket for PerpMarket.Data;
    using Position for Position.Data;

    /**
     * @dev Validates whether the margin requirements are acceptable after withdrawing.
     */
    function validatePositionPostWithdraw(Position.Data storage position, PerpMarket.Data storage market) private view {
        uint256 marginUsd = Margin.getMarginUsd(position.accountId, market);
        PerpMarketConfiguration.Data storage marketConfig = PerpMarketConfiguration.load(position.marketId);

        uint256 oraclePrice = market.getOraclePrice();

        // Ensure does not lead to instant liquidation.
        if (position.isLiquidatable(marginUsd, oraclePrice, marketConfig)) {
            revert ErrorUtil.CanLiquidatePosition(position.accountId);
        }

        (uint256 im, , ) = Position.getLiquidationMarginUsd(position.size, oraclePrice, marketConfig);
        if (marginUsd < im) {
            revert ErrorUtil.InsufficientMargin();
        }
    }

    /**
     * @inheritdoc IMarginModule
     */
    function transferTo(uint128 accountId, uint128 marketId, address collateralType, int256 amountDelta) external {
        if (collateralType == address(0)) {
            revert ErrorUtil.ZeroAddress();
        }

        Account.exists(accountId);
        PerpMarket.Data storage market = PerpMarket.exists(marketId);

        // Prevent collateral transfers when there's a pending order.
        Order.Data storage order = market.orders[accountId];
        if (order.sizeDelta != 0) {
            revert ErrorUtil.OrderFound(accountId);
        }

        PerpMarketConfiguration.GlobalData storage globalConfig = PerpMarketConfiguration.load();
        Margin.GlobalData storage globalMarginConfig = Margin.load();
        Margin.Data storage accountMargin = Margin.load(accountId, marketId);

        uint256 absAmountDelta = MathUtil.abs(amountDelta);
        uint256 availableAmount = accountMargin.available[collateralType];

        Margin.CollateralType storage collateral = globalMarginConfig.supported[collateralType];
        uint256 maxAllowable = collateral.maxAllowable;
        if (maxAllowable == 0) {
            revert ErrorUtil.UnsupportedCollateral(collateralType);
        }

        // TODO: When the collateral is sUSD then we can burn the sUSD for more credit rather than depositing.

        if (amountDelta > 0) {
            // Positive means to deposit into the markets.

            // Verify whether this will exceed the maximum allowable collateral amount.
            if (availableAmount + absAmountDelta > maxAllowable) {
                revert ErrorUtil.MaxCollateralExceeded(absAmountDelta, maxAllowable);
            }

            // TODO: Rename `available` to `collaterals`.
            accountMargin.available[collateralType] += absAmountDelta;
            IERC20(collateralType).transferFrom(msg.sender, address(this), absAmountDelta);
            globalConfig.synthetix.depositMarketCollateral(marketId, collateralType, absAmountDelta);

            emit Transfer(msg.sender, address(this), absAmountDelta);
        } else if (amountDelta < 0) {
            // Negative means to withdraw from the markets.

            // Verify the collateral previously associated to this account is enough to cover withdrawals.
            if (availableAmount < absAmountDelta) {
                revert ErrorUtil.InsufficientCollateral(collateralType, availableAmount, absAmountDelta);
            }

            accountMargin.available[collateralType] -= absAmountDelta;

            // If an open position exists, verify this does _not_ place them into instant liquidation.
            Position.Data storage position = market.positions[accountId];
            if (position.size != 0) {
                validatePositionPostWithdraw(position, market);
            }

            globalConfig.synthetix.withdrawMarketCollateral(marketId, collateralType, absAmountDelta);
            IERC20(collateralType).transferFrom(address(this), msg.sender, absAmountDelta);
            emit Transfer(address(this), msg.sender, absAmountDelta);
        } else {
            // A zero amount is a no-op.
            return;
        }
    }

    /**
     * @inheritdoc IMarginModule
     */
    function setCollateralConfiguration(
        address[] calldata collateralTypes,
        bytes32[] calldata oracleNodeIds,
        uint128[] calldata maxAllowables
    ) external {
        OwnableStorage.onlyOwner();

        PerpMarketConfiguration.GlobalData storage globalMarketConfig = PerpMarketConfiguration.load();
        Margin.GlobalData storage globalMarginConfig = Margin.load();

        // Clear existing collateral configuration to be replaced with new.
        uint256 existingCollateralLength = globalMarginConfig.supportedAddresses.length;
        for (uint256 i = 0; i < existingCollateralLength; ) {
            address collateralType = globalMarginConfig.supportedAddresses[i];
            delete globalMarginConfig.supported[collateralType];

            // Revoke access after wiping collateral from supported market collateral.
            //
            // TODO: Add this back later. Synthetix IERC20.approve contracts throw InvalidParameter when amount = 0.
            //
            // IERC20(collateralType).approve(address(this), 0);

            unchecked {
                i++;
            }
        }
        delete globalMarginConfig.supportedAddresses;

        // Update with passed in configuration.
        uint256 newCollateralLength = collateralTypes.length;
        address[] memory newSupportedAddresses = new address[](newCollateralLength);
        for (uint256 i = 0; i < newCollateralLength; ) {
            address collateralType = collateralTypes[i];
            if (collateralType == address(0)) {
                revert ErrorUtil.ZeroAddress();
            }

            // Perform this operation _once_ when this collateral is added as a supported collateral.
            uint128 maxAllowable = maxAllowables[i];
            IERC20(collateralType).approve(address(globalMarketConfig.synthetix), maxAllowable);
            IERC20(collateralType).approve(address(this), maxAllowable);
            globalMarginConfig.supported[collateralType] = Margin.CollateralType(oracleNodeIds[i], maxAllowable);
            newSupportedAddresses[i] = collateralType;

            unchecked {
                i++;
            }
        }
        globalMarginConfig.supportedAddresses = newSupportedAddresses;

        emit CollateralConfigured(msg.sender, newCollateralLength);
    }

    // --- Views --- //

    /**
     * @inheritdoc IMarginModule
     */
    function getConfiguredCollaterals() external view returns (AvailableCollateral[] memory collaterals) {
        Margin.GlobalData storage globalMarginConfig = Margin.load();

        uint256 length = globalMarginConfig.supportedAddresses.length;
        collaterals = new AvailableCollateral[](length);

        for (uint256 i = 0; i < length; ) {
            address _type = globalMarginConfig.supportedAddresses[i];
            Margin.CollateralType storage c = globalMarginConfig.supported[_type];
            collaterals[i] = AvailableCollateral(_type, c.oracleNodeId, c.maxAllowable);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @inheritdoc IMarginModule
     */
    function getNotionalValueUsd(uint128 accountId, uint128 marketId) external view returns (uint256) {
        return Margin.getNotionalValueUsd(accountId, marketId);
    }
}
