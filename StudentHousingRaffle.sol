// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title Student Housing Raffle
/// @notice Participants pay a refundable 0.03 ETH commitment deposit.
///         They may withdraw before the registration deadline. After the draw,
///         losers can claim refunds, while the winner's deposit stays locked
///         until the organizer confirms the off-chain accommodation agreement.

contract Raffle is VRFConsumerBaseV2Plus {
    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    uint256 public constant ENTRY_FEE = 0.03 ether;
    uint256 public constant WINNER_RESPONSE_PERIOD = 72 hours;

    // Registration closes at this timestamp. Set during deployment.
    uint256 public immutable raffleEndTime;

    bytes32 public merkleRoot;

    // -------------------------------------------------------------------------
    // Participant and raffle state
    // -------------------------------------------------------------------------

    mapping(address => bool) public hasEntered;

    // One-based array position: 0 means the address is not in participants.
    // If a participant is at array index 0, this mapping stores 1.
    mapping(address => uint256) private participantIndexPlusOne;

    // Kept as the final draw snapshot after the raffle is closed.
    address payable[] public participants;

    address public winner;
    address public runnerUp;

    // isRaffleClosed becomes true when the draw is requested or the raffle is cancelled.
    bool public isRaffleClosed;
    bool public raffleCancelled;
    bool public isDrawFinalized;

    // Winner commitment / settlement state.
    bool public winnerAccepted;
    bool public winnerDepositReleased;
    uint256 public drawTimeStamp;
    uint256 public winnerAcceptanceDeadline;

    // Deposits forfeited after a selected winner fails to accept.
    // The owner withdraws this balance separately, so the promotion flow
    // does not depend on the owner's wallet being able to receive ETH.
    uint256 public forfeitedDepositBalance;

    uint256 public s_requestId;

    // -------------------------------------------------------------------------
    // Chainlink VRF v2.5 configuration
    // -------------------------------------------------------------------------

    bytes32 internal keyHash =
        0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae; // This is the key hash for the Chainlink VRF v2.5 on the target network. It identifies the specific oracle job that will generate verifiable randomness.

    uint256 internal subscriptionId =
        88610757455220946505939063638212623854967879934969213305708313877492627991365; // This is the subscription ID for the Chainlink VRF v2.5 on the target network. It is used to pay for the randomness request and must be funded with LINK tokens.

    uint32 internal callbackGasLimit = 500000; // This is the gas limit for the callback function that receives the random number from Chainlink VRF v2.5. It must be set high enough to cover the gas cost of processing the randomness and updating the contract state.
    uint16 internal requestConfirmations = 3; // This is the number of confirmations that the Chainlink VRF v2.5 oracle will wait before fulfilling the randomness request. It helps ensure that the random number is not influenced by blockchain reorgs or other manipulations.
    uint32 internal numWords = 1; // This is the number of random words (uint256 values) that the Chainlink VRF v2.5 oracle will return in response to the randomness request. In this case, we only need one random word to select a winner.

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ParticipantEntered(address indexed participant); // This event is emitted when a participant successfully enters the raffle. It includes the participant's address as an indexed parameter, allowing for easy filtering and searching in the event logs.
    event ParticipantWithdrew(address indexed participant, uint256 amount); // This event is emitted when a participant withdraws from the raffle before the registration deadline. It includes the participant's address and the amount of ETH refunded (0.03 ETH) as parameters.
    event RefundClaimed(address indexed participant, uint256 amount); // This event is emitted when a participant claims their refund after the raffle is cancelled or after losing the draw. It includes the participant's address and the amount of ETH refunded (0.03 ETH) as parameters.
    event RaffleCancelled(); // This event is emitted when the raffle is cancelled due to insufficient participants (fewer than two). It does not include any parameters, as it simply indicates that the raffle has been cancelled and participants can claim their refunds.
    event winnerPicked(address indexed winner, address indexed runnerUp); // This is an event that is emitted when a winner is picked. It contains the address of the winner and the runner-up.
    event WinnerAcceptanceDeadlineSet(uint256 acceptanceDeadline); // This event is emitted when the winner acceptance deadline is set. It contains the timestamp of the acceptance deadline.
    event WinnerAccepted(address indexed winner); // This event is emitted when the winner accepts the prize. It contains the address of the winner.
    event WinnerDepositReleased(address indexed winner, uint256 amount); // This event is emitted when the winner's deposit is released after they have accepted the prize. It contains the address of the winner and the amount of ETH released (0.03 ETH).
    event RunnerUpPromoted(address indexed previousWinner, address indexed newWinner, uint256 newAcceptanceDeadline); // This event is emitted when the runner-up is promoted to winner after the original winner fails to accept the prize. It contains the address of the previous winner, the address of the new winner (the promoted runner-up), and the new acceptance deadline for the promoted winner.
    event DepositForfeited(address indexed participant, uint256 amount); // This event is emitted when a participant's deposit is forfeited due to failing to accept the prize within the acceptance deadline. It contains the address of the participant and the amount of ETH forfeited (0.03 ETH).
    event FinalWinnerExpired(address indexed participant, uint256 amount); // This event is emitted when the final winner's acceptance period expires without them accepting the prize. It contains the address of the participant and the amount of ETH forfeited (0.03 ETH).
    event ForfeitedDepositsWithdrawn(address indexed owner, uint256 amount); // This event is emitted when the raffle owner withdraws the forfeited deposits after the final winner fails to accept the prize. It contains the address of the owner and the amount of ETH withdrawn (the total forfeited deposits).
    event RandomnessRequested(uint256 indexed requestId);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _merkleRoot Root hash for the approved student-wallet whitelist.
    /// @param _vrfCoordinator Chainlink VRF Coordinator address for the target network.
    /// @param _registrationDuration How long registration remains open, in seconds.

    constructor(
        bytes32 _merkleRoot,
        address _vrfCoordinator,
        uint256 _registrationDuration
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_registrationDuration > 0, "Registration duration must be positive");

        merkleRoot = _merkleRoot;
        raffleEndTime = block.timestamp + _registrationDuration;
    }

    // -------------------------------------------------------------------------
    // 1. Entry and withdrawal before deadline
    // -------------------------------------------------------------------------

    /// @notice Enter the raffle by providing a valid Merkle proof and exactly 0.03 ETH.

    function enterRaffle(bytes32[] calldata merkleProof) external payable {
        require(!isRaffleClosed && !raffleCancelled, "Raffle is closed");
        require(block.timestamp < raffleEndTime, "Registration period has ended");
        require(msg.value == ENTRY_FEE, "Incorrect deposit amount");
        require(!hasEntered[msg.sender], "You already have an active entry");

        // This leaf format must exactly match the off-chain Merkle-tree generator.
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(
            MerkleProof.verify(merkleProof, merkleRoot, leaf),
            "Not on the verified student whitelist"
        );

        hasEntered[msg.sender] = true;
        participants.push(payable(msg.sender));
        participantIndexPlusOne[msg.sender] = participants.length;

        emit ParticipantEntered(msg.sender);
    }

    /// @notice Withdraw before the registration deadline and receive the full deposit back.
    function withdraw() external {
        require(!isRaffleClosed && !raffleCancelled, "Raffle is closed");
        require(block.timestamp < raffleEndTime, "Withdrawal deadline has passed");
        require(hasEntered[msg.sender], "No active raffle entry");

        // Effects: remove the participant and clear their active-entry status
        // before making the external ETH transfer.
        _removeParticipant(msg.sender);
        hasEntered[msg.sender] = false;

        _sendETH(payable(msg.sender), ENTRY_FEE);
        emit ParticipantWithdrew(msg.sender, ENTRY_FEE);
    }

    /// @dev Remove an address from the array in O(1) using swap-and-pop method.
    function _removeParticipant(address participant) internal {
        
        // STEP 1: Retrieve the participant's stored array position.
        // The mapping stores the actual index plus one.
        uint256 indexPlusOne = participantIndexPlusOne[participant];

        // STEP 2: Ensure the participant exists in the array.
        // Zero means that the address has no registered array position.
        require(indexPlusOne != 0, "Participant not found");

        // STEP 3: Convert the one-based mapping value
        // into the actual zero-based array index.
        uint256 index = indexPlusOne - 1;

        // STEP 4: Identify the last element in the participants array.
        uint256 lastIndex = participants.length - 1;

        // STEP 5: Check whether the participant is already the last element.
        // If not, we need to replace their position with the last participant.
        // This is when swap-and-pop method used: replace the participant to remove with the last participant, then pop the last element.
        if (index != lastIndex) {

            // STEP 6: Retrieve the wallet address of the last participant.
            address payable lastParticipant = participants[lastIndex];

            // STEP 7: Move the last participant into the withdrawn
            // participant's previous position.
            participants[index] = lastParticipant;

            // STEP 8: Update the moved participant's mapping
            // to reflect their new array position.
            participantIndexPlusOne[lastParticipant] = index + 1;
        }

        // STEP 9: Remove the last element from the array.
        participants.pop();

        // STEP 10: Delete the withdrawn participant's mapping entry.
        delete participantIndexPlusOne[participant];
    }

    // -------------------------------------------------------------------------
    // 2. Close registration and request randomness (This is when VRF Chainlink comes into play)
    // -------------------------------------------------------------------------

    /// @notice Only WoVe owner can trigger the draw, but only after registration has ended.
    function pickWinner() external {
        require(msg.sender == owner(), "Only WoVe can trigger the draw");
        require(!isRaffleClosed && !raffleCancelled, "Raffle is already closed");
        require(block.timestamp >= raffleEndTime, "Registration period is still open");
        require(participants.length >= 2, "Not enough participants");

        // Lock entry and withdrawal before requesting randomness.
        isRaffleClosed = true;

        s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash, // This is the gas lane
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        emit RandomnessRequested(s_requestId);
    }

    /// @notice If fewer than two people entered, cancel and let all remaining participants refund.
    // WORTH NOTICING: It'd be bether to turn it into internal and only the OWNER can call it
    function cancelIfNotEnoughParticipants() external {
        require(!isRaffleClosed && !raffleCancelled, "Raffle is already closed");
        require(block.timestamp >= raffleEndTime, "Registration period is still open");
        require(participants.length < 2, "There are enough participants for a draw");

        isRaffleClosed = true;
        raffleCancelled = true;

        emit RaffleCancelled();
    }

    /// @notice Claim the full deposit after the raffle is cancelled for having fewer than two entrants.
    function claimCancelledRefund() external {
        require(raffleCancelled, "Raffle was not cancelled");
        require(hasEntered[msg.sender], "No refundable entry");

        _removeParticipant(msg.sender);
        hasEntered[msg.sender] = false;

        _sendETH(payable(msg.sender), ENTRY_FEE);
        emit RefundClaimed(msg.sender, ENTRY_FEE);
    }

    // -------------------------------------------------------------------------
    // 3. Chainlink VRF callback and winner selection
    // -------------------------------------------------------------------------

    function fulfillRandomWords(
        uint256 /* requestId */,
        uint256[] calldata randomWords
    ) internal override {
        require(randomWords.length > 0, "No random word received");
        require(participants.length >= 2, "Not enough participants");

        uint256 winnerIndex = randomWords[0] % participants.length;
        uint256 runnerUpIndex = (winnerIndex + 1) % participants.length;

        winner = participants[winnerIndex];
        runnerUp = participants[runnerUpIndex];

        drawTimeStamp = block.timestamp;
        winnerAcceptanceDeadline = block.timestamp + WINNER_RESPONSE_PERIOD;
        isDrawFinalized = true;

        emit winnerPicked(winner, runnerUp);
        emit WinnerAcceptanceDeadlineSet(winnerAcceptanceDeadline);
    }

    // -------------------------------------------------------------------------
    // 4. Post-draw deposits and refunds
    // -------------------------------------------------------------------------

    /// @notice Losing participants claim their own refunds (pull-payment model).
    ///         The current winner is locked; the runner-up is locked until the
    ///         original winner accepts or the runner-up is promoted.

    // NOTE: Maybe we can automate this
    function claimLoserRefund() external {
        require(isDrawFinalized, "The draw is not finalized yet");
        require(hasEntered[msg.sender], "No refundable entry");
        require(msg.sender != winner, "Winner deposit is locked as commitment");

        if (!winnerAccepted) {
            require(msg.sender != runnerUp, "Runner-up deposit is reserved for fallback");
        }

        hasEntered[msg.sender] = false;
        delete participantIndexPlusOne[msg.sender];

        _sendETH(payable(msg.sender), ENTRY_FEE);
        emit RefundClaimed(msg.sender, ENTRY_FEE);
    }

    /// @notice The selected winner must accept within 72 hours of selection/promotion.
    function acceptPrize() external {
        require(isDrawFinalized, "The draw is not finalized yet");
        require(winner != address(0), "There is no active winner");
        require(msg.sender == winner, "Only the selected winner can accept");
        require(!winnerAccepted, "Winner has already accepted");
        require(block.timestamp < winnerAcceptanceDeadline, "Winner acceptance period has expired");

        winnerAccepted = true;
        emit WinnerAccepted(msg.sender);
    }

    /// @notice Organizer releases the winner's commitment deposit after confirming
    ///         the off-chain accommodation agreement has been completed.
    function releaseWinnerDeposit() external {
        require(msg.sender == owner(), "Only the raffle owner can release the deposit");
        require(isDrawFinalized && winnerAccepted, "Winner has not accepted");
        require(!winnerDepositReleased, "Winner deposit already released");
        require(winner != address(0), "There is no active winner");

        address payable acceptedWinner = payable(winner);

        winnerDepositReleased = true;
        hasEntered[acceptedWinner] = false;
        delete participantIndexPlusOne[acceptedWinner];

        _sendETH(acceptedWinner, ENTRY_FEE);
        emit WinnerDepositReleased(acceptedWinner, ENTRY_FEE);
    }

    /// @notice After the current winner's 72-hour period expires without acceptance,
    ///         promote the runner-up. Anyone may call this function to execute the promotion.

    // NOTE: Maybe the owner and/or the runner-up only that able to execute this
    function claimNext() external {
        require(isDrawFinalized, "The draw is not finalized yet");
        require(!winnerAccepted, "The winner has already accepted");
        require(runnerUp != address(0), "No runner-up is available");
        require(block.timestamp >= winnerAcceptanceDeadline, "Winner response period has not expired");

        address previousWinner = winner;
        address promotedWinner = runnerUp;

        // The previous winner failed to accept, so their 0.03 ETH is forfeited.
        hasEntered[previousWinner] = false;
        delete participantIndexPlusOne[previousWinner];
        forfeitedDepositBalance += ENTRY_FEE;
        emit DepositForfeited(previousWinner, ENTRY_FEE);

        // Promote the runner-up and give them a fresh 72-hour acceptance period.
        winner = promotedWinner;
        runnerUp = address(0); // This design provides one runner-up fallback only.
        winnerAccepted = false;
        winnerDepositReleased = false;
        winnerAcceptanceDeadline = block.timestamp + WINNER_RESPONSE_PERIOD;

        emit RunnerUpPromoted(previousWinner, promotedWinner, winnerAcceptanceDeadline);
    }

    /// @notice If the promoted runner-up also fails to accept within their 72-hour
    ///         window, their deposit is forfeited and the raffle ends without a winner.
    function expireFinalWinner() external {
        require(isDrawFinalized, "The draw is not finalized yet");
        require(runnerUp == address(0), "A runner-up fallback is still available");
        require(winner != address(0), "There is no active winner");
        require(!winnerAccepted, "Winner has already accepted");
        require(block.timestamp >= winnerAcceptanceDeadline, "Winner response period has not expired");

        address expiredWinner = winner;

        hasEntered[expiredWinner] = false;
        delete participantIndexPlusOne[expiredWinner];
        forfeitedDepositBalance += ENTRY_FEE;
        winner = address(0);

        emit DepositForfeited(expiredWinner, ENTRY_FEE);
        emit FinalWinnerExpired(expiredWinner, ENTRY_FEE);
    }

    /// @notice Owner withdraws deposits forfeited by winners who did not accept.
    function withdrawForfeitedDeposits() external {
        require(msg.sender == owner(), "Only the raffle owner can withdraw forfeitures");

        uint256 amount = forfeitedDepositBalance;
        require(amount > 0, "No forfeited deposits available");

        forfeitedDepositBalance = 0;
        _sendETH(payable(owner()), amount);

        emit ForfeitedDepositsWithdrawn(owner(), amount);
    }

    // -------------------------------------------------------------------------
    // Internal ETH transfer helper
    // -------------------------------------------------------------------------

    /// @dev Uses call and requires the transfer to succeed. Callers update state first.
    function _sendETH(address payable recipient, uint256 amount) internal {
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
}
