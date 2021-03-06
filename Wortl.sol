// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
pragma experimental ABIEncoderV2;

// import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";


contract Wortl is ChainlinkClient, ConfirmedOwner, VRFConsumerBaseV2, KeeperCompatible, ERC721 {
    VRFCoordinatorV2Interface COORDINATOR;
    using Chainlink for Chainlink.Request;
    using Strings for string;

    string[] public allowedWords = ["atoms", "birds", "curat", "deeds", "echos", "fands", "gajos", "halid", "incel", "jenny", "kirby", "lifts", "marts"]; // TODO: use oracle to fetch from ipfs
    string public wordOfTheDay = allowedWords[0]; // this gets set with Keeper
    bytes[5] public bytesWordOfTheDay;

    /**
    * Chainlink Oracle
    */
    uint256 public volume;
    bytes32 private jobId;
    uint256 private fee;

    /**
    * Chainlink Keepers
    * Use an interval in seconds and a timestamp to slow execution of Upkeep
    */
    uint public immutable interval;
    uint public lastTimeStamp;

    /**
    * Chainlink VRF
    */
    uint64 s_subscriptionId;
    address vrfCoordinator = 0x6168499c0cFfCaCD319c818142124B7A15E857ab;
    bytes32 keyHash = 0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc;
    uint32 callbackGasLimit = 100000;
    uint16 requestConfirmations = 3;
    uint32 numWords =  2;
    uint256[] public s_randomWords = [86340239181704960512648170967626326199340276652033804226278067086070082662992];
    uint256 public s_requestId;
    address s_owner;

    uint256 tokenId = 0;

    struct GuessOfTheDayWithDeposit {
        uint8 remainingGuesses;
        uint256 deposit;
        uint256 timestamp; //block.timestamp
        string word;
    }

    address[] public whoPaidToPlay;
    mapping(address => GuessOfTheDayWithDeposit) public guessOfTheDayWithDeposit;
    mapping(address => bool) public canMintPrize;

    event RequestVolume(bytes32 indexed requestId, uint256 volume);
    event Log(string data, uint int_data);

    constructor(uint64 subscriptionId, uint256 updateInterval, string memory name, string memory symbol) ConfirmedOwner(msg.sender) VRFConsumerBaseV2(vrfCoordinator) ERC721(name, symbol) {
        // VRF (Rinkeby)
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_owner = msg.sender;
        s_subscriptionId = subscriptionId;

        // Offchain Workers (Kovan)
        setChainlinkToken(0xa36085F69e2889c224210F603D836748e7dC0088);
        setChainlinkOracle(0x74EcC8Bdeb76F2C6760eD2dc8A46ca5e581fA656);
        jobId = "ca98366cc7314957b8c012c72f05aeeb";
        fee = (1 * LINK_DIVISIBILITY) / 10; // 0,1 * 10**18 (Varies by network and job)\

        // Keeper
        interval = updateInterval;
        lastTimeStamp = block.timestamp;
    }

    // Keeper
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory /* performData */) {
        upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
        // We don't use the checkData in this example. The checkData is defined when the Upkeep was registered.
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        //We highly recommend revalidating the upkeep in the performUpkeep function
        if ((block.timestamp - lastTimeStamp) > interval ) {
            lastTimeStamp = block.timestamp;

            // once a day, reset the word of the day
            getWordOfTheDay();
            
            // once a day, you will reset all the remaining guesses of people that paid to play
            for (uint8 i = 0; i < whoPaidToPlay.length; i++) {
                if (guessOfTheDayWithDeposit[whoPaidToPlay[i]].timestamp - block.timestamp >= 1 days) {
                    guessOfTheDayWithDeposit[whoPaidToPlay[i]] = GuessOfTheDayWithDeposit({
                        timestamp: block.timestamp,
                        deposit: guessOfTheDayWithDeposit[whoPaidToPlay[i]].deposit,
                        word: wordOfTheDay,
                        remainingGuesses: 5
                    });
                }
            }
        }
        // We don't use the performData in this example. The performData is generated by the Keeper's call to your checkUpkeep function
    }

    function payToPlay() payable public {
        // console.log("msg.value: ", msg.value);
        require(msg.value >= 0.01 * 10e17, "Need to pay at least 0.01 ETH to play");

        // if you already paid, too fucking bad thanks for the money.
        whoPaidToPlay.push(msg.sender);

        guessOfTheDayWithDeposit[msg.sender] = GuessOfTheDayWithDeposit({
            timestamp: block.timestamp,
            deposit: msg.value,
            word: wordOfTheDay,
            remainingGuesses: 5
        });
    }

    /**
     * Create a Chainlink request to retrieve API response, find the target
     * data, then multiply by 1000000000000000000 (to remove decimal places from data).
     */
    function requestVolumeData() public returns (bytes32 requestId) {
        Chainlink.Request memory req = buildChainlinkRequest(jobId, address(this), this.fulfill.selector);

        // Set the URL to perform the GET request on
        req.add("get", "https://wortl.mypinata.cloud/ipfs/Qmdym7vjNyizQ8W3Yvu3PEvXdaUShfyPjstZMGT8PUt8fx");

        // Set the path to find the desired data in the API response, where the response format is:
        //    {
        //      words: {
                    //    0: "hello",
                    //    1: "atoms",
                    //    2: "birds"
        //      }
        // }
        req.add("path", "words"); // Chainlink nodes 1.0.0 and later support this format

        // Sends the request 
        return sendChainlinkRequest(req, fee);
    }

    /**
     * Receive the response in the form of uint3256
     */
    function fulfill(bytes32 _requestId, uint256 _volume) public recordChainlinkFulfillment(_requestId) {
        emit RequestVolume(_requestId, _volume);
        volume = _volume;
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(msg.sender, link.balanceOf(address(this))), 'Unable to transfer');
    }

    // Assumes the subscription is funded sufficiently.
    function requestRandomWords() external onlyOwner {
        // Will revert if subscription is not set and funded.
        s_requestId = COORDINATOR.requestRandomWords(
        keyHash,
        s_subscriptionId,
        requestConfirmations,
        callbackGasLimit,
        numWords
        );
    }
    
    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        s_randomWords = randomWords;
    }

    function getWordOfTheDay() public returns (string memory wotd) {
        require(s_randomWords.length > 0, "Random index should be set");

        emit Log("", s_randomWords[0]);

        uint index = s_randomWords[0] % allowedWords.length - 1;
        
        wordOfTheDay = allowedWords[index];

        emit Log(wordOfTheDay, index);

        return wordOfTheDay;
    }

    function isAllowed(string memory word) internal view returns (bool) {
        for (uint i = 0; i < allowedWords.length; i++) {
            if (keccak256(bytes(allowedWords[i])) == keccak256(bytes(word))) {
                return true;
            }
        }
        return false;
    }

    function letterExistsInWordOfTheDay(bytes32 guessLetterHash) internal view returns (bool) {
        for (uint8 i = 0; i < 5; i++) {
            bytes memory answerLetter = new bytes(1);
            answerLetter[0] = bytes(wordOfTheDay)[i];

            if (guessLetterHash == keccak256(abi.encodePacked(answerLetter))) {
                return true;
            }
        }
        return false;
    }

    /*
    *   @param letter(N) - letters of the word in the allowed word list. It needs to come in a letter at a time because string comparison is not straighforward in solidity.
    *   @param attempt_number - from 1 up to 6 attempts
    *   @return result - list of length 5 of green(0) (correct letter correct place),
                         yellow(1) (correct letter wrong place), or blank(2) (letter not in word)
    */
    function guess(string memory guessedWord) public returns (uint8[5] memory res) {
        require(isAllowed(guessedWord), "word is not in allowed word list.");
        require(keccak256(bytes(guessOfTheDayWithDeposit[msg.sender].word)) == keccak256(bytes(wordOfTheDay)) && guessOfTheDayWithDeposit[msg.sender].remainingGuesses > 0, "no more guesses remaining today.") ;

        uint8[5] memory winCondition = [0, 0, 0, 0, 0];
        uint8[5] memory result = [0, 0, 0, 0, 0];

        for (uint8 i = 0; i < 5; i++) {
            bytes memory guessLetter = new bytes(1);
            guessLetter[0] = bytes(guessedWord)[i];

            bytes memory answerLetter = new bytes(1);
            answerLetter[0] = bytes(wordOfTheDay)[i];
            
            // console.log("guess letter ", string(guessLetter));
            // console.log("answer letter ", string(answerLetter));

            if (keccak256(guessLetter) == keccak256(answerLetter)) {
                // console.log("inside first if => ", string(guessLetter));
                result[i] = 0; // green
            } 
            else if (letterExistsInWordOfTheDay(keccak256(guessLetter))) {
                // console.log("inside second if => ", string(guessLetter), " exists in another position of ", wordOfTheDay);
                result[i] = 1; // yellow
            } 
            else {
                // console.log("inside third if => ", string(guessLetter), " does not exist in ", wordOfTheDay);
                result[i] = 2; // blank
            }
        }

        guessOfTheDayWithDeposit[msg.sender].remainingGuesses -= 1;
        guessOfTheDayWithDeposit[msg.sender].timestamp = block.timestamp;

        // Win condition
        if (keccak256(abi.encodePacked(result)) == keccak256(abi.encodePacked(winCondition))) {
            canMintPrize[msg.sender] = true;
        }

        return result;
    }

    function withdrawDeposit() external {
        require (guessOfTheDayWithDeposit[msg.sender].deposit > 0, "you can only withdraw if you have a deposit.");

        payable (msg.sender).transfer(guessOfTheDayWithDeposit[msg.sender].deposit);
    }

    function mintWinnersSoulboundNFTWithWordOfTheDay() external {
        require(canMintPrize[msg.sender] == true, "You can only mint if you won the Wortle.");

        _safeMint(msg.sender, tokenId);

        tokenId += 1;
    }
}
