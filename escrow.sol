pragma solidity ^0.8.3;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for contracts conforming to ERC-721
 */
interface ERC721Interface {
    function ownerOf(uint256 _tokenId) external view returns (address _owner);
}

contract EGGVERSEEscrow is Initializable, OwnableUpgradeable {
    uint256 private constant MAX_INT = 2**256 - 1;

    mapping(address => mapping(address => uint256)) balanceOf;
    address ethAddr;
    address adminAddress;
    address eggtAddr;

    event Deposit(
        address from,
        address contractAddr,
        uint256 amount
    );

    event Withdraw(
        address from,
        address to,
        address contractAddr,
        uint256 amount
    );

    // EVENTS
    event BidFirstAuctionCreated(
        address _to,
        string _tokenURI,
        uint8 _auctionType,
        uint256 _auctionCategory,
        uint256 expiresAt, // timestamp
        uint256 _price, // 고정가, 시작가
        uint256 _stock, // bulk 경매 재고
        address _tokenAddress, // NFT 판매시 NFT 주소
        uint256 _tokenId, // 판매할 NFT ID
        uint256 chainId,  // 판매할 NFT chain Id
        uint256 bidPrice // 맨 처음 입찰 금액
    );

    // [_tokenAddress][_tokenId][bidIndex]

    function initialize() public initializer {
        __Ownable_init();
        ethAddr = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    function openBidFirstAuction(address nftAddress, uint256 tokenId, string memory _tokenURI, uint256 amount) public payable {
        // bidder는 NFT 소유자가 아닐 것.
        address ownerOfNft = ERC721Interface(nftAddress).ownerOf(tokenId);
        require(ownerOfNft != msg.sender, "cannot bid NFT by NFT owner");
        require(amount != 0 || msg.value != 0, "bid price cannot be 0");

        if(amount != 0){
            // amount가 있다면 eggt로 입금
            deposit(amount);
        }
        else{
            // amount가 없다면 eth로 입금
            deposit();
        }

        // tokenURI는 다룰 수 있는 포맷으로 변경하여 처리해 보내줌
        emit BidFirstAuctionCreated(
            ownerOfNft, // auction NFT는 어드민에게 발행한다.
            _tokenURI,
            1, // 경매방식은 일반 경매
            18, // 카테고리는 기타
            MAX_INT, // 무기한 - int(MAX)으로 표기
            0, // 판매 희망가는 0
            1, // 재고 1
            nftAddress, // 구매할 NFT 주소
            tokenId, // 구매할 NFT 토큰 ID
            block.chainid,
            amount != 0? amount: msg.value
        );
    }

    // deposit ETH
    function deposit() public payable {
        balanceOf[ethAddr][msg.sender] += msg.value;

        emit Deposit(msg.sender, ethAddr, msg.value);
    }

    // deposit EGGT Token
    function deposit(uint256 amount) public {
        IERC20(eggtAddr).transferFrom(msg.sender, address(this), amount);
        balanceOf[eggtAddr][msg.sender] += amount;

        emit Deposit(msg.sender, eggtAddr, amount);
    }

    // Deposit fund on escrow using allowance
    // And emit bidding event
    function deposit(address from, uint256 amount) public onlyAdmin {
        IERC20(eggtAddr).transferFrom(from, address(this), amount);
        balanceOf[eggtAddr][from] += amount;

        emit Deposit(from, eggtAddr, amount);
    }

    // Deposit fund on escrow using allowance
    // And emit bidding event
    function forward(address from, address to, uint256 amount) public onlyAdmin {
        IERC20(eggtAddr).transferFrom(from, to, amount);

        emit Deposit(from, eggtAddr, amount);
        emit Withdraw(from, to, eggtAddr, amount);
    }

    // Withdraw fund
    // And emit Auction finished event
    function withdraw(address from, address payable to, uint256 amount, address contractAddress) public onlyAdmin {
        if(ethAddr == contractAddress) {
            to.transfer(amount);
        } else {
            IERC20(contractAddress).transfer(to, amount);
        }
        balanceOf[contractAddress][from] -= amount;

        emit Withdraw(from, to, contractAddress, amount);
    }

    function setEggtAddress(address _eggtAddr) public onlyOwner {
        eggtAddr = _eggtAddr;
    }
    /**
     * @dev set bid Contract address
     */
    function setAdmin(address _admin) public onlyOwner {
        adminAddress = _admin;
    }

    modifier onlyAdmin() {
        require(adminAddress == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function queryBalance(address _contract, address _EOA) public view returns (uint256) {
        return balanceOf[_contract][_EOA];
    }
}