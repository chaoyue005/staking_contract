// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        bytes memory data = abi.encodeCall(token.transfer, (to, amount));
        bytes memory result = _callOptionalReturn(address(token), data);
        if (result.length > 0) {
            require(abi.decode(result, (bool)), "ERC20 transfer failed");
        }
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bytes memory data = abi.encodeCall(token.transferFrom, (from, to, amount));
        bytes memory result = _callOptionalReturn(address(token), data);
        if (result.length > 0) {
            require(abi.decode(result, (bool)), "ERC20 transferFrom failed");
        }
    }

    function forceApprove(IERC20 token, address spender, uint256 amount) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, amount));
        bytes memory result = _callOptionalReturn(address(token), approvalCall);

        if (result.length == 0 || abi.decode(result, (bool))) {
            return;
        }

        _callOptionalReturn(address(token), abi.encodeCall(token.approve, (spender, 0)));
        bytes memory secondResult = _callOptionalReturn(address(token), approvalCall);
        if (secondResult.length > 0) {
            require(abi.decode(secondResult, (bool)), "ERC20 approve failed");
        }
    }

    function _callOptionalReturn(address target, bytes memory data) private returns (bytes memory) {
        (bool success, bytes memory returndata) = target.call(data);
        require(success, "ERC20 low-level call failed");
        return returndata;
    }
}

abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Owner is zero");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Owner is zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrancy");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract StakingBBS is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Category {
        Job,
        Housing
    }

    enum PostStatus {
        None,
        Active,
        Hidden,
        Closed,
        Expired
    }

    struct Post {
        address author;
        Category category;
        PostStatus status;
        uint256 principal;
        uint256 shares;
        uint64 createdAt;
        uint64 expiresAt;
        string metadataURI;
    }

    struct AccountingPreview {
        uint256 userAssets;
        uint256 platformAssets;
        uint256 userYield;
        uint256 platformYield;
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant AUTHOR_YIELD_BPS = 8_000;
    uint256 public constant PLATFORM_YIELD_BPS = 2_000;
    uint256 public constant POST_DURATION = 30 days;

    IERC20 public immutable stakingToken;
    IERC20 public immutable aToken;
    IAavePool public immutable aavePool;

    address public treasury;
    uint256 public immutable minStake;

    uint256 public nextPostId;
    uint256 public totalPrincipal;
    uint256 public totalPostShares;
    uint256 public accountedUserAssets;
    uint256 public accountedPlatformAssets;

    mapping(uint256 => Post) private _posts;

    event PostCreated(
        uint256 indexed postId,
        address indexed author,
        Category indexed category,
        uint256 amount,
        uint256 shares,
        uint256 expiresAt,
        string metadataURI
    );
    event StakeAdded(uint256 indexed postId, address indexed author, uint256 amount, uint256 shares);
    event PostHidden(uint256 indexed postId);
    event PostClosed(
        uint256 indexed postId,
        address indexed author,
        PostStatus indexed finalStatus,
        uint256 principalReturned,
        uint256 authorYield
    );
    event PlatformYieldClaimed(address indexed treasury, uint256 amount);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event YieldSynced(uint256 userYield, uint256 platformYield);

    constructor(
        address initialOwner,
        address treasury_,
        address stakingToken_,
        address aToken_,
        address aavePool_,
        uint256 minStake_
    ) Ownable(initialOwner) {
        require(treasury_ != address(0), "Treasury is zero");
        require(stakingToken_ != address(0), "Token is zero");
        require(aToken_ != address(0), "aToken is zero");
        require(aavePool_ != address(0), "Pool is zero");
        require(minStake_ > 0, "Min stake is zero");

        treasury = treasury_;
        stakingToken = IERC20(stakingToken_);
        aToken = IERC20(aToken_);
        aavePool = IAavePool(aavePool_);
        minStake = minStake_;

        IERC20(stakingToken_).forceApprove(aavePool_, type(uint256).max);
    }

    function createPost(
        Category category,
        string calldata metadataURI,
        uint256 amount
    ) external nonReentrant returns (uint256 postId) {
        require(bytes(metadataURI).length > 0, "Metadata is empty");
        require(amount >= minStake, "Stake below minimum");

        _syncYield();

        postId = ++nextPostId;
        uint256 shares = _mintShares(amount);

        _posts[postId] = Post({
            author: msg.sender,
            category: category,
            status: PostStatus.Active,
            principal: amount,
            shares: shares,
            createdAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + POST_DURATION),
            metadataURI: metadataURI
        });

        totalPrincipal += amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        _depositToAave(amount);

        emit PostCreated(
            postId,
            msg.sender,
            category,
            amount,
            shares,
            block.timestamp + POST_DURATION,
            metadataURI
        );
    }

    function addStake(uint256 postId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount is zero");

        Post storage post = _posts[postId];
        require(post.author != address(0), "Post not found");
        require(post.author == msg.sender, "Not author");
        require(post.status == PostStatus.Active, "Post not active");
        require(block.timestamp < post.expiresAt, "Post expired");

        _syncYield();

        uint256 shares = _mintShares(amount);

        post.principal += amount;
        post.shares += shares;
        totalPrincipal += amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        _depositToAave(amount);

        emit StakeAdded(postId, msg.sender, amount, shares);
    }

    function hidePost(uint256 postId) external onlyOwner {
        Post storage post = _posts[postId];
        require(post.author != address(0), "Post not found");
        require(post.status == PostStatus.Active, "Post not active");

        post.status = PostStatus.Hidden;
        emit PostHidden(postId);
    }

    function closePostAndWithdraw(uint256 postId) external nonReentrant returns (uint256 payout) {
        Post storage post = _posts[postId];
        require(post.author != address(0), "Post not found");
        require(post.author == msg.sender, "Not author");
        require(
            post.status == PostStatus.Active || post.status == PostStatus.Hidden,
            "Post already settled"
        );

        _syncYield();
        payout = _settlePost(postId, msg.sender, block.timestamp >= post.expiresAt);
    }

    function expirePost(uint256 postId) external nonReentrant returns (uint256 payout) {
        Post storage post = _posts[postId];
        require(post.author != address(0), "Post not found");
        require(
            post.status == PostStatus.Active || post.status == PostStatus.Hidden,
            "Post already settled"
        );
        require(block.timestamp >= post.expiresAt, "Post still active");

        _syncYield();
        payout = _settlePost(postId, post.author, true);
    }

    function claimPlatformYield(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount is zero");

        _syncYield();
        require(amount <= accountedPlatformAssets, "Amount exceeds platform yield");

        accountedPlatformAssets -= amount;
        _pullLiquidity(amount);
        stakingToken.safeTransfer(treasury, amount);

        emit PlatformYieldClaimed(treasury, amount);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Treasury is zero");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function managedAssets() public view returns (uint256) {
        return stakingToken.balanceOf(address(this)) + aToken.balanceOf(address(this));
    }

    function previewPlatformClaimable() external view returns (uint256) {
        AccountingPreview memory preview = _previewAccounting();
        return preview.platformAssets;
    }

    function getPost(uint256 postId) external view returns (Post memory) {
        Post memory post = _posts[postId];
        require(post.author != address(0), "Post not found");
        return post;
    }

    function previewPostPayout(uint256 postId) external view returns (uint256 totalPayout, uint256 authorYield) {
        Post storage post = _posts[postId];
        require(post.author != address(0), "Post not found");

        AccountingPreview memory preview = _previewAccounting();
        totalPayout = _previewPostValue(post, preview.userAssets);
        authorYield = totalPayout > post.principal ? totalPayout - post.principal : 0;
    }

    function isExpired(uint256 postId) external view returns (bool) {
        Post storage post = _posts[postId];
        require(post.author != address(0), "Post not found");
        return block.timestamp >= post.expiresAt;
    }

    function syncYield() external {
        _syncYield();
    }

    function _settlePost(
        uint256 postId,
        address recipient,
        bool expired
    ) internal returns (uint256 payout) {
        Post storage post = _posts[postId];

        payout = _previewPostValue(post, accountedUserAssets);
        uint256 principalReturned = post.principal;
        uint256 authorYield = payout > principalReturned ? payout - principalReturned : 0;

        accountedUserAssets -= payout;
        totalPostShares -= post.shares;
        totalPrincipal -= principalReturned;

        post.principal = 0;
        post.shares = 0;
        post.status = expired ? PostStatus.Expired : PostStatus.Closed;

        _pullLiquidity(payout);
        stakingToken.safeTransfer(recipient, payout);

        emit PostClosed(postId, recipient, post.status, principalReturned, authorYield);
    }

    function _previewAccounting() internal view returns (AccountingPreview memory preview) {
        preview.userAssets = accountedUserAssets;
        preview.platformAssets = accountedPlatformAssets;

        uint256 managed = managedAssets();
        uint256 accountedTotal = preview.userAssets + preview.platformAssets;

        if (managed <= accountedTotal) {
            return preview;
        }

        uint256 freshYield = managed - accountedTotal;

        if (accountedTotal == 0) {
            preview.platformAssets += freshYield;
            preview.platformYield = freshYield;
            return preview;
        }

        uint256 yieldFromUserCapital;
        uint256 yieldFromPlatformCapital;

        if (preview.platformAssets == 0) {
            yieldFromUserCapital = freshYield;
        } else if (preview.userAssets == 0) {
            yieldFromPlatformCapital = freshYield;
        } else {
            yieldFromUserCapital = (freshYield * preview.userAssets) / accountedTotal;
            yieldFromPlatformCapital = freshYield - yieldFromUserCapital;
        }

        uint256 userYieldShare = (yieldFromUserCapital * AUTHOR_YIELD_BPS) / BPS_DENOMINATOR;
        uint256 platformYieldShare = freshYield - userYieldShare;

        preview.userAssets += userYieldShare;
        preview.platformAssets += platformYieldShare;
        preview.userYield = userYieldShare;
        preview.platformYield = platformYieldShare;
    }

    function _syncYield() internal {
        AccountingPreview memory preview = _previewAccounting();

        if (
            preview.userAssets == accountedUserAssets &&
            preview.platformAssets == accountedPlatformAssets
        ) {
            return;
        }

        accountedUserAssets = preview.userAssets;
        accountedPlatformAssets = preview.platformAssets;

        emit YieldSynced(preview.userYield, preview.platformYield);
    }

    function _mintShares(uint256 amount) internal returns (uint256 shares) {
        if (totalPostShares == 0 || accountedUserAssets == 0) {
            shares = amount;
        } else {
            shares = (amount * totalPostShares) / accountedUserAssets;
        }

        require(shares > 0, "Shares round to zero");

        totalPostShares += shares;
        accountedUserAssets += amount;
    }

    function _previewPostValue(Post storage post, uint256 userAssets) internal view returns (uint256) {
        if (post.shares == 0 || totalPostShares == 0) {
            return 0;
        }

        if (post.shares == totalPostShares) {
            return userAssets;
        }

        return (post.shares * userAssets) / totalPostShares;
    }

    function _depositToAave(uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        aavePool.supply(address(stakingToken), amount, address(this), 0);
    }

    function _pullLiquidity(uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        uint256 liquidBalance = stakingToken.balanceOf(address(this));
        if (liquidBalance >= amount) {
            return;
        }

        aavePool.withdraw(address(stakingToken), amount - liquidBalance, address(this));
    }
}
