pragma solidity ^0.4.18;

import './IceBreakerARToken.sol';
import './zeppelin/lifecycle/Pausable.sol';

contract IceBreakerARTokenSale is Pausable {
  using SafeMath for uint256;

  /**
  * @dev Supporter struct to allow tracking supporters KYC status and referrer address
  */
  struct Supporter {
    bool hasKYC;
    address referrerAddress;
  }

  /**
  * @dev External Supporter struct to allow tracking reserved amounts by supporter
  */
  struct ExternalSupporter {
    uint256 reservedAmount;
  }

  /**
   * @dev Token Sale States
   */
  enum TokenSaleState {Private, Pre, Main, Finished}

  // Variables
  mapping(address => Supporter) public supportersMap; // Mapping with all the Token Sale participants (Private excluded)
  mapping(address => ExternalSupporter) public externalSupportersMap; // Mapping with external supporters
  IceBreakerARToken public token; // ERC20 Token contract address
  address public vaultWallet; // Wallet address to which ETH and Company Reserve Tokens get forwarded
  address public kycWallet; // Wallet address for the KYC server
  uint256 public tokensSold; // How many tokens have been sold
  uint256 public tokensReserved; // How many tokens have been reserved
  uint256 public maxTxGasPrice; // Maximum transaction gas price allowed for fair-chance transactions
  TokenSaleState public currentState; // current Sale state

  uint256 public constant ONE_MILLION = 10 ** 6; // One million for token cap calculation reference
  uint256 public constant ONE_THOUSAND = 10 ** 3; // One thousand for token cap calculation reference
  uint256 public constant PRE_SALE_TOKEN_CAP = 57500 * ONE_THOUSAND * 10 ** 18; // Maximum amount that can be sold during the Pre Sale period
  uint256 public constant TOKEN_SALE_CAP = 212500 * ONE_THOUSAND * 10 ** 18; // Maximum amount of tokens that can be sold by this contract
  uint256 public constant TOTAL_TOKENS_SUPPLY = 300 * ONE_MILLION * 10 ** 18; // Total supply that will be minted
  uint256 public constant MIN_ETHER = 0.1 ether; // Minimum ETH Contribution allowed during the crowd sale

  /* Rate */
  uint256 public tokenBaseRate; // Base rate

  uint256 public referrerBonusRate; // Referrer Bonus Rate with 2 decimals (500 for 5% bonus for example)

  /**
    * @dev Modifier to only allow Owner or KYC Wallet to execute a function
    */
  modifier onlyOwnerOrKYCWallet() {
    require(msg.sender == owner || msg.sender == kycWallet);
    _;
  }

  /**
  * Event for token purchase logging
  * @param purchaser The wallet address that bought the tokens
  * @param value How many Weis were paid for the purchase
  * @param amount The amount of tokens purchased
  */
  event TokenPurchase(address indexed purchaser, uint256 value, uint256 amount);

  /**
  * Event for token reservation 
  * @param wallet The beneficiary wallet address
  * @param amount The amount of tokens
  */
  event TokenReservation(address indexed wallet, uint256 amount);

  /**
  * Event for token reservation confirmation
  * @param wallet The beneficiary wallet address
  * @param amount The amount of tokens
  */
  event TokenReservationConfirmation(address indexed wallet, uint256 amount);

  /**
  * Event for token reservation cancellation
  * @param wallet The beneficiary wallet address
  * @param amount The amount of tokens
  */
  event TokenReservationCancellation(address indexed wallet, uint256 amount);

  /**
   * Event for kyc status change logging
   * @param user User address
   * @param isApproved KYC approval state
   */
  event KYC(address indexed user, bool isApproved);

  /**
   * Event for referrer set
   * @param user User address
   * @param referrerAddress Referrer address
   */
  event ReferrerSet(address indexed user, address indexed referrerAddress);

  /**
   * Event for referral bonus incomplete
   * @param userAddress User address
   * @param missingAmount Missing Amount
   */
  event ReferralBonusIncomplete(address indexed userAddress, uint256 missingAmount);

  /**
   * Event for referral bonus minted
   * @param userAddress User address
   * @param amount Amount minted
   */
  event ReferralBonusMinted(address indexed userAddress, uint256 amount);

  /**
   * Constructor
   * @param _vaultWallet Vault address
   * @param _kycWallet KYC address
   * @param _tokenBaseRate Token Base rate (Tokens/ETH)
   * @param _referrerBonusRate Referrer Bonus rate (2 decimals, ex 250 for 2.5%)
   * @param _maxTxGasPrice Maximum gas price allowed when buying tokens
   */
  function IceBreakerARTokenSale(
    address _vaultWallet,
    address _kycWallet,
    uint256 _tokenBaseRate,
    uint256 _referrerBonusRate,
    uint256 _maxTxGasPrice
  )
  public
  {
    require(_vaultWallet != address(0));
    require(_kycWallet != address(0));
    require(_tokenBaseRate > 0);
    require(_referrerBonusRate > 0);
    require(_maxTxGasPrice > 0);

    vaultWallet = _vaultWallet;
    kycWallet = _kycWallet;
    tokenBaseRate = _tokenBaseRate;
    referrerBonusRate = _referrerBonusRate;
    maxTxGasPrice = _maxTxGasPrice;

    tokensSold = 0;
    tokensReserved = 0;

    token = new IceBreakerARToken();

    // init sale state;
    currentState = TokenSaleState.Private;
  }

  /* fallback function can be used to buy tokens */
  function() public payable {
    buyTokens();
  }

  /* low level token purchase function */
  function buyTokens() public payable whenNotPaused {
    // Do not allow if gasprice is bigger than the maximum
    // This is for fair-chance for all contributors, so no one can
    // set a too-high transaction price and be able to buy earlier
    require(tx.gasprice <= maxTxGasPrice);

    // make sure we're in pre or main sale period
    require(isPublicTokenSaleRunning());

    // check if KYC ok
    require(userHasKYC(msg.sender));

    // check user is sending enough Wei for the stage's rules
    require(aboveMinimumPurchase());

    address sender = msg.sender;
    uint256 weiAmountSent = msg.value;

    // calculate token amount
    uint256 bonusMultiplier = getBonusMultiplier(weiAmountSent);
    uint256 newTokens = weiAmountSent.mul(tokenBaseRate).mul(bonusMultiplier).div(100);

    // check totals and mint the tokens
    checkTotalsAndMintTokens(sender, newTokens, false);

    // Log Event
    TokenPurchase(sender, weiAmountSent, newTokens);

    // forward the funds to the vault wallet
    vaultWallet.transfer(msg.value);
  }

  /**
  * @dev Reserve Tokens
  * @param _wallet Destination Address
  * @param _amount Amount of tokens
  */
  function reserveTokens(address _wallet, uint256 _amount) public onlyOwner {
    // check amount positive
    require(_amount > 0);
    // check destination address not null
    require(_wallet != address(0));

    // make sure the sale hasn't ended yet
    require(!hasEnded());

    // check cap
    uint256 totalTokensReserved = tokensReserved.add(_amount);

    if (isMainSaleRunning()) {
      require(tokensSold + totalTokensReserved <= TOKEN_SALE_CAP);
    } else {
      require(tokensSold + totalTokensReserved <= PRE_SALE_TOKEN_CAP);
    }

    // update total reserved
    tokensReserved = totalTokensReserved;

    // save user reservation
    externalSupportersMap[_wallet].reservedAmount = externalSupportersMap[_wallet].reservedAmount.add(_amount);

    // Log Event
    TokenReservation(_wallet, _amount);
  }

  /**
  * @dev Confirm Reserved Tokens
  * @param _wallet Destination Address
  * @param _amount Amount of tokens
  */
  function confirmReservedTokens(address _wallet, uint256 _amount) public onlyOwner {
    // check amount positive
    require(_amount > 0);
    // check destination address not null
    require(_wallet != address(0));

    // make sure the sale hasn't ended yet
    require(!hasEnded());

    // check amount not more than reserved
    require(_amount <= externalSupportersMap[_wallet].reservedAmount);

    // check totals and mint the tokens
    checkTotalsAndMintTokens(_wallet, _amount, true);

    // Log Event
    TokenReservationConfirmation(_wallet, _amount);
  }

  /**
   * @dev Cancel Reserved Tokens
   * @param _wallet Destination Address
   * @param _amount Amount of tokens
   */
  function cancelReservedTokens(address _wallet, uint256 _amount) public onlyOwner {
    // check amount positive
    require(_amount > 0);
    // check destination address not null
    require(_wallet != address(0));

    // make sure the sale hasn't ended yet
    require(!hasEnded());

    // check amount not more than reserved
    require(_amount <= externalSupportersMap[_wallet].reservedAmount);

    // update total reserved
    tokensReserved = tokensReserved.sub(_amount);

    // update user reservation
    externalSupportersMap[_wallet].reservedAmount = externalSupportersMap[_wallet].reservedAmount.sub(_amount);

    // Log Event
    TokenReservationCancellation(_wallet, _amount);
  }

  /**
  * @dev Check totals and Mint tokens
  * @param _wallet Destination Address
  * @param _amount Amount of tokens
  */
  function checkTotalsAndMintTokens(address _wallet, uint256 _amount, bool _fromReservation) private {
    // check that we have not yet reached the cap
    uint256 totalTokensSold = tokensSold.add(_amount);

    uint256 totalTokensReserved = tokensReserved;
    if (_fromReservation) {
      totalTokensReserved = totalTokensReserved.sub(_amount);
    }

    if (isMainSaleRunning()) {
      require(totalTokensSold + totalTokensReserved <= TOKEN_SALE_CAP);
    } else {
      require(totalTokensSold + totalTokensReserved <= PRE_SALE_TOKEN_CAP);
    }

    // update contract state
    tokensSold = totalTokensSold;

    if (_fromReservation) {
      externalSupportersMap[_wallet].reservedAmount = externalSupportersMap[_wallet].reservedAmount.sub(_amount);
      tokensReserved = totalTokensReserved;
    }

    // mint the tokens
    token.mint(_wallet, _amount);

    address userReferrer = getUserReferrer(_wallet);

    if (userReferrer != address(0)) {
      // Mint Referrer bonus
      mintReferralShare(_amount, userReferrer, referrerBonusRate);
    }
  }

  /**
   * @dev Mint Referral Share
   * @param _amount Amount of tokens
   * @param _userAddress User Address
   * @param _bonusRate Bonus rate (2 decimals)
   */
  function mintReferralShare(uint256 _amount, address _userAddress, uint256 _bonusRate) private {
    // calculate max tokens available
    uint256 currentCap;

    if (isMainSaleRunning()) {
      currentCap = TOKEN_SALE_CAP;
    } else {
      currentCap = PRE_SALE_TOKEN_CAP;
    }

    uint256 maxTokensAvailable = currentCap - tokensSold - tokensReserved;

    // check if we have enough tokens
    uint256 fullShare = _amount.mul(_bonusRate).div(10000);
    if (fullShare <= maxTokensAvailable) {
      // mint the tokens
      token.mint(_userAddress, fullShare);

      // update state
      tokensSold = tokensSold.add(fullShare);

      // log event
      ReferralBonusMinted(_userAddress, fullShare);
    }
    else {
      // mint the available tokens
      token.mint(_userAddress, maxTokensAvailable);

      // update state
      tokensSold = tokensSold.add(maxTokensAvailable);

      // log events

      ReferralBonusMinted(_userAddress, maxTokensAvailable);
      ReferralBonusIncomplete(_userAddress, fullShare - maxTokensAvailable);
    }
  }

  /**
  * @dev Start Presale
  */
  function startPreSale() public onlyOwner {
    // make sure we're in the private sale state
    require(currentState == TokenSaleState.Private);

    // move to presale
    currentState = TokenSaleState.Pre;
  }

  /**
  * @dev Go back to private sale
  */
  function goBackToPrivateSale() public onlyOwner {
    // make sure we're in the pre sale
    require(currentState == TokenSaleState.Pre);

    // go back to private
    currentState = TokenSaleState.Private;
  }

  /**
  * @dev Start Main sale
  */
  function startMainSale() public onlyOwner {
    // make sure we're in the presale state
    require(currentState == TokenSaleState.Pre);

    // move to main sale
    currentState = TokenSaleState.Main;
  }

  /**
  * @dev Go back to Presale
  */
  function goBackToPreSale() public onlyOwner {
    // make sure we're in the main sale
    require(currentState == TokenSaleState.Main);

    // go back to presale
    currentState = TokenSaleState.Pre;
  }

  /**
  * @dev Ends the operation of the contract
  */
  function finishContract() public onlyOwner {
    // make sure we're in the main sale
    require(currentState == TokenSaleState.Main);

    // make sure there are no pending reservations
    require(tokensReserved == 0);

    // mark sale as finished
    currentState = TokenSaleState.Finished;

    // send the unsold tokens to the vault wallet
    uint256 unsoldTokens = TOKEN_SALE_CAP.sub(tokensSold);
    token.mint(vaultWallet, unsoldTokens);

    // send the company reserve tokens to the vault wallet
    uint256 notForSaleTokens = TOTAL_TOKENS_SUPPLY.sub(TOKEN_SALE_CAP);
    token.mint(vaultWallet, notForSaleTokens);

    // finish the minting of the token, so that transfers are allowed
    token.finishMinting();

    // transfer ownership of the token contract to the owner,
    // so it isn't locked to be a child of the crowd sale contract
    token.transferOwnership(owner);
  }

  /**
  * @dev Updates the maximum allowed gas price that can be used when calling buyTokens()
  * @param _newMaxTxGasPrice The new maximum gas price
  */
  function updateMaxTxGasPrice(uint256 _newMaxTxGasPrice) public onlyOwner {
    require(_newMaxTxGasPrice > 0);
    maxTxGasPrice = _newMaxTxGasPrice;
  }

  /**
   * @dev Updates the Vault Wallet address
   * @param _vaultWallet The new vault wallet
   */
  function updateVaultWallet(address _vaultWallet) public onlyOwner {
    require(_vaultWallet != address(0));
    vaultWallet = _vaultWallet;
  }

  /**
   * @dev Updates the KYC Wallet address
   * @param _kycWallet The new kyc wallet
   */
  function updateKYCWallet(address _kycWallet) public onlyOwner {
    require(_kycWallet != address(0));
    kycWallet = _kycWallet;
  }

  /**
  * @dev Approve user's KYC
  * @param _user User Address
  */
  function approveUserKYC(address _user) onlyOwnerOrKYCWallet public {
    require(_user != address(0));

    Supporter storage sup = supportersMap[_user];
    sup.hasKYC = true;
    KYC(_user, true);
  }

  /**
   * @dev Disapprove user's KYC
   * @param _user User Address
   */
  function disapproveUserKYC(address _user) onlyOwnerOrKYCWallet public {
    require(_user != address(0));

    Supporter storage sup = supportersMap[_user];
    sup.hasKYC = false;
    KYC(_user, false);
  }

  /**
   * @dev Approve user's KYC and sets referrer
   * @param _user User Address
   * @param _referrerAddress Referrer Address
   */
  function approveUserKYCAndSetReferrer(address _user, address _referrerAddress) onlyOwnerOrKYCWallet public {
    require(_user != address(0));

    Supporter storage sup = supportersMap[_user];
    sup.hasKYC = true;
    sup.referrerAddress = _referrerAddress;

    // log events
    KYC(_user, true);
    ReferrerSet(_user, _referrerAddress);
  }

  /**
  * @dev check if private sale is running
  */
  function isPrivateSaleRunning() public view returns (bool) {
    return (currentState == TokenSaleState.Private);
  }

  /**
  * @dev check if pre sale or main sale are running
  */
  function isPublicTokenSaleRunning() public view returns (bool) {
    return (isPreSaleRunning() || isMainSaleRunning());
  }

  /**
  * @dev check if pre sale is running
  */
  function isPreSaleRunning() public view returns (bool) {
    return (currentState == TokenSaleState.Pre);
  }

  /**
  * @dev check if main sale is running
  */
  function isMainSaleRunning() public view returns (bool) {
    return (currentState == TokenSaleState.Main);
  }

  /**
  * @dev check if sale has ended
  */
  function hasEnded() public view returns (bool) {
    return (currentState == TokenSaleState.Finished);
  }

  /**
  * @dev Check if user has passed KYC
  * @param _user User Address
  */
  function userHasKYC(address _user) public view returns (bool) {
    return supportersMap[_user].hasKYC;
  }

  /**
  * @dev Get User's referrer address
  * @param _user User Address
  */
  function getUserReferrer(address _user) public view returns (address) {
    return supportersMap[_user].referrerAddress;
  }

  /**
  * @dev Get User's reserved amount
  * @param _user User Address
  */
  function getReservedAmount(address _user) public view returns (uint256) {
    return externalSupportersMap[_user].reservedAmount;
  }

  /**
   * @dev Returns the bonus multiplier to calculate the purchase rate
   * @param _weiAmount Purchase amount
   */
  function getBonusMultiplier(uint256 _weiAmount) internal view returns (uint256) {
    if (isMainSaleRunning()) {
      return 100;
    }
    else if (isPreSaleRunning()) {
      return 120;
    }
    else {
      // Safeguard but this should never happen as we should have checked before that we're in public sale mode
      revert();
    }
  }

  /**
   * @dev Check if the user is buying above the required minimum
   */
  function aboveMinimumPurchase() internal view returns (bool) {
    return msg.value >= MIN_ETHER;
  }
}