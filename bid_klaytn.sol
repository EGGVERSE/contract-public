// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Interface for contracts conforming to ERC-721
 */
interface ERC721Interface {
    function transferFrom(address _from, address _to, uint256 _tokenId) external;
    function supportsInterface(bytes4) external view returns (bool);
    function ownerOf(uint256 _tokenId) external view returns (address _owner);
}

contract ERC721BidKlaytn is OwnableUpgradeable, PausableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;

    uint256 private constant MAX_INT = 2**256 - 1;

    bytes4 public constant ERC721_Received = 0x150b7a02;
    mapping(address => mapping(address => uint256)) balanceOf;
    address ethAddr;
    address adminAddress;
    // address eggtAddr;

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
    event BidCreated(
        uint256 indexed _tokenId,
        address indexed _bidder,
        uint256 _price,
        string _name,
        string _description,
        string _bidImage
    );

    // EVENTS
    event OrderAccepted(
        uint256 indexed _tokenId,
        bytes _data
    );

    // EVENTS
    event OrderFinalized(
        uint256 indexed _tokenId,
        address indexed _orderer,
        string cid
    );

    // EVENTS
    event AuctionCreated(
        address _to,
        string _tokenURI,
        uint8 _auctionType,
        uint256 _auctionCategory,
        uint256 expiresAt, // timestamp
        uint256 _price, // 고정가, 시작가
        uint256 _stock, // bulk 경매 재고
        address _tokenAddress, // NFT 판매시 NFT 주소
        uint256 _tokenId, // 판매할 NFT ID
        uint256 chainId  // 판매할 NFT chain Id
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
        uint256 chainId, // 판매할 NFT chain Id
        uint256 bidPrice // 맨 처음 입찰 금액
    );

    event AuctionBurnt(
        uint256 _tokenId
    );

    // EVENTS
    event BidFirstAuctionNFTTransfered(
        address _tokenAddress, // NFT 판매시 NFT 주소
        uint256 _tokenId, // 판매할 NFT ID
        address _owner // 보낸이
    );


    function initialize() public initializer {
        __Ownable_init();
        __Pausable_init();
        ethAddr = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    /**
     * @dev Mint NFTs. Only the owner can call it.
     */
    function mint(
        address _to,
        string memory _tokenURI,
        uint8 _auctionType,
        uint256 _auctionCategory,
        uint256 expiresAt, // timestamp
        uint256 _price, // 고정가, 시작가
        uint256 _stock, // bulk 경매 재고
        address _tokenAddress, // NFT 판매시 NFT 주소
        uint256 _id, // NFT 판매시 NFT 토큰 id
        uint256 chainId // 사용 X. 포맷을 동일하게 하기 위함
    ) external /* onlyOwner */ {
        // 프론트, 컨트랙트 타임스탬프 오차를 보정하기 위해 앞뒤 5분 여유 둠
        // require(expiresAt >= block.timestamp - 5 minutes && expiresAt <= block.timestamp + 30 days + 5 minutes, "Invalid auction duration");

        emit AuctionCreated(_to, _tokenURI, _auctionType, _auctionCategory, expiresAt, _price, _stock, _tokenAddress, _id, block.chainid);
    }

    function openBidFirstAuction(address nftAddress, uint256 tokenId, string memory _tokenURI) public payable {
        // bidder는 NFT 소유자가 아닐 것.
        address ownerOfNft = ERC721Interface(nftAddress).ownerOf(tokenId);
        require(ownerOfNft != msg.sender, "cannot bid NFT by NFT owner");
        require(msg.value != 0, "bid price cannot be 0");

        _deposit();

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
            msg.value //초기 입찰가 - 초기 bidder의 bid를 처리하기 위함 
        );
    }

    function burn(
        uint256 _tokenId
    ) external {
        emit AuctionBurnt(_tokenId);
    }

   /**
    * @dev Used as the only way to accept a bid. 
    * The token owner should send the token to this contract using safeTransferFrom.
    * The last parameter (bytes) should be the bid id.
    * @notice  The ERC721 smart contract calls this function on the recipient
    * after a `safetransfer`. This function MAY throw to revert and reject the
    * transfer. Return of other than the magic value MUST result in the
    * transaction being reverted.
    * Note: 
    * Contract address is always the message sender.
    * This method should be seen as 'acceptBid'.
    * It validates that the bid id matches an active bid for the bid token.
    * @param _operator // transfer를 호출한 sender
    * @param _from // 원래 토큰 소유자
    * @param _tokenId The NFT identifier which is being transferred
    * @param _data Additional data with no specified format
    * @return `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
    */
    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes memory _data
    )
        public
        returns (bytes4)
    {
        if(_data.length <= 32){
            // (bidfirst) 낙찰하기 위해서는 먼저 NFT를 에스크로에 넣어야 한다. 그 로직.
            emit BidFirstAuctionNFTTransfered(msg.sender, _tokenId, _from);
        }
        else{
            openNftMarket(_from, _tokenId, _data);
        }
        return ERC721_Received;
    }

    function openNftMarket(address _from, uint256 _tokenId, bytes memory _data) internal{
        (
            string memory _tokenURI,
            uint8 _auctionType,
            uint256 _auctionCategory,
            uint256 expiresAt, // timestamp
            uint256 _price // 고정가, 시작가
        ) = abi.decode(_data, (string, uint8, uint256, uint256, uint256));


        // _requireERC721(msg.sender);
        // 일반 경매, 고정가 일반 경매만 허용
        require(_auctionType == 1 || _auctionType == 3, "Only auction/fixed auction can sell NFT");

        // 사실상 mint 함수와 동일
        emit AuctionCreated(_from, _tokenURI, _auctionType, _auctionCategory, expiresAt, _price, 1, msg.sender, _tokenId, block.chainid);
    }

    /**
    * @dev Convert bytes to uint8
    * @param _data - bytes
    * @return bytes32
    */
    function _bytesToUint8(bytes memory _data) internal pure returns (uint8) {
        require(_data.length == 8, "The data should be 8 bytes length");

        uint8 result;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            result := mload(add(_data, 0x8))
        }
        return result;
    }

    // 낙찰, 판매 이벤트 잡아서 백엔드에서 호출하는 함수
    // 들고있는 NFT를 전송한다
    function transferNft(address _tokenAddress, uint256 _tokenId, address to) public onlyAdmin {
        ERC721Interface(_tokenAddress).transferFrom(address(this), to, _tokenId);
    }

    /**
    * @dev Check if the token has a valid ERC721 implementation
    * @param _tokenAddress - address of the token
    */
    function _requireERC721(address _tokenAddress) internal view {
        require(isContract(_tokenAddress), "Token should be a contract");

        ERC721Interface token = ERC721Interface(_tokenAddress);
        bytes4 ERC721_Interface = 0x80ac58cd;
        require(
            token.supportsInterface(ERC721_Interface),
            "Token has an invalid ERC721 implementation"
        );
    }

    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }


    function placeBid(
        uint256 _tokenId,
        string memory _name,
        string memory _description,
        string memory _bidImage
    ) payable public {

        _deposit();

        emit BidCreated(
            _tokenId,
            msg.sender,
            msg.value,
            _name,
            _description,
            _bidImage
        );
    }

    function placeBidForReverseAuction(
        uint256 _tokenId,
        uint256 _price,
        string memory _name,
        string memory _description,
        string memory _bidImage
    ) public {

        emit BidCreated(
            _tokenId,
            msg.sender,
            _price,
            _name,
            _description,
            _bidImage
        );
    }

    function finalizeOrder(uint256 _tokenId, string memory cid) public 
    {
        emit OrderFinalized(_tokenId, msg.sender, cid);
    }

    function acceptBid(uint256 _tokenId, bytes memory _data) public {
        emit OrderAccepted(_tokenId, _data);
    }

    // deposit ETH
    // 역경매 낙찰시 호출
    function deposit() payable public {
        _deposit();
    }

    function getBalance(address addr) public view returns (uint256){
        return balanceOf[ethAddr][addr];
    }

    // deposit ETH
    function _deposit() internal {
        balanceOf[ethAddr][msg.sender] += msg.value;

        emit Deposit(msg.sender, ethAddr, msg.value);
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

    // function setEggtAddress(address _eggtAddr) public onlyOwner {
    //     eggtAddr = _eggtAddr;
    // }
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

}