// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

/**
 * @title Interface for contracts conforming to ERC-20
 */
interface ERC20Interface {
    function balanceOf(address from) external view returns (uint256);
    function transfer(address to, uint tokens) external returns (bool);
    function transferFrom(address from, address to, uint tokens) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}


/**
 * @title Interface for contracts conforming to ERC-721
 */
interface ERC721Interface {
    function ownerOf(uint256 _tokenId) external view returns (address _owner);
    function transferFrom(address _from, address _to, uint256 _tokenId) external;
    function supportsInterface(bytes4) external view returns (bool);
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function mint(address _to, string calldata _tokenURI) external returns (uint256);
    function burn(uint256 _tokenId) external;
}

interface CertificateInterface {
    function transferOwnership(address newOwner) external;
}

interface ERC721Verifiable is ERC721Interface {
    function verifyFingerprint(uint256, bytes memory) external view returns (bool);
}


contract ERC721BidStorage {
    // 182 days - 26 weeks - 6 months
    uint256 public constant MAX_BID_DURATION = 182 days;
    uint256 public constant MIN_BID_DURATION = 1 minutes;
    uint256 public constant ONE_MILLION = 1000000;
    bytes4 public constant ERC721_Interface = 0x80ac58cd;
    bytes4 public constant ERC721_Received = 0x150b7a02;
    bytes4 public constant ERC721Composable_ValidateFingerprint = 0x8f9f4b63;
    address public _certificateAddress;
    
    struct Bid {
        // Bid Id
        bytes32 id;
        // Bidder address 
        address bidder;
        // ERC721 address
        address tokenAddress;
        // ERC721 token id
        uint256 tokenId;
        // Price for the bid in wei 
        uint256 price;
        // Time when this bid ends 
        uint256 expiresAt;
        // Fingerprint for composable
        bytes fingerprint;
        
        string name;

        string description;

        string bidImage;
    }

    struct Order {
        // Orderer address
        address orderer;
        // Bidder address 
        address bidder;
        // ERC721 address
        address tokenAddress;
        // ERC721 token id
        uint256 tokenId;
        // Price for the bid in wei 
        uint256 price;
        // Time when this bid ends 
        uint256 expiresAt;
    }

    // EGGT token
    ERC20Interface public eggtToken;

    // Bid by token address => token id => bid index => bid
    mapping(address => mapping(uint256 => mapping(uint256 => Bid))) internal bidsByToken;
    // Order by token address => token id => msg.sender => order
    mapping(address => mapping(uint256 => mapping(address => Order))) internal orders;
    // Bid count by token address => token id => bid counts
    mapping(address => mapping(uint256 => uint256)) public bidCounterByToken;
    // Index of the bid at bidsByToken mapping by bid id => bid index
    mapping(bytes32 => uint256) public bidIndexByBidId;
    // Bid id by token address => token id => bidder address => bidId
    mapping(address => mapping(uint256 => mapping(address => bytes32))) 
    public 
    bidIdByTokenAndBidder;


    mapping(uint256 => uint256) public ownerCutPerMillion;

    // EVENTS
    event BidCreated(
        bytes32 _id,
        address indexed _tokenAddress,
        uint256 indexed _tokenId,
        address indexed _bidder,
        uint256 _price,
        uint256 _expiresAt,
        bytes _fingerprint,
        string _name,
        string _description,
        string _bidImage
    );
    
    event BidAccepted(
        bytes32 _id,
        address indexed _tokenAddress,
        uint256 indexed _tokenId,
        address _bidder,
        address indexed _seller,
        uint256 _price,
        uint256 _fee
    );

    event BidCancelled(
        bytes32 _id,
        address indexed _tokenAddress,
        uint256 indexed _tokenId,
        address indexed _bidder
    );

    event OrderCreated(
        address indexed _orderer,
        address indexed _bidder,
        address indexed _tokenAddress,
        uint256 _tokenId,
        uint256 _price,
        uint256 _expiresAt
    );

    event OrderAccepted(
        address indexed _orderer,
        address indexed _bidder,
        address indexed _tokenAddress,
        uint256 _tokenId,
        uint256 _price,
        uint256 _fee
    );

    event OrderCancelled(
        address indexed _orderer,
        address indexed _bidder,
        address indexed _tokenAddress
    );

    event ChangedOwnerCutPerMillion(uint256 categoryId, uint256 _ownerCutPerMillion);
}


contract ERC721Bid is OwnableUpgradeable, PausableUpgradeable, ERC721BidStorage {
    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;
    using ECDSAUpgradeable for bytes32;

    address public auctionContract;
    address public adminAddress;

    /**
    * @dev Constructor of the contract.
    * @param _eggtToken - address of the eggt token
    * @param _owner - address of the owner for the contract
    */
    function initialize(address _eggtToken, address _owner) public initializer {

        __Ownable_init();
        __Pausable_init();

        eggtToken = ERC20Interface(_eggtToken);
        transferOwnership(_owner);
    }

    function setEggtToken(address _eggtToken) external onlyOwner{
        eggtToken = ERC20Interface(_eggtToken);
    }

    // 클레이튼 뿐만 아니라 백엔드에서 직접 컨콜하는 것 포함
    //   기존에는 클립 처리용으로만 사용했는데, bid first NFT 마켓 생성 기능을 추가하며 사용하게 됨.
    /**
    * @dev Place a bid for an ERC721 token.
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the token id
    * @param _price - uint256 of the price for the bid
    * @param _duration - uint256 of the duration in seconds for the bid
    * @param _name - string of bid name
    * @param _description - string of bid description
    */
    function placeBidFromKlaytn(
        address _tokenAddress, 
        uint256 _tokenId,
        address _bidder,
        uint256 _price,
        uint256 _duration,
        string memory _name,
        string memory _description,
        string memory _bidImage
    )
        public
        onlyAdmin
    {
        uint8 auctionType = IEGGVERSEAuction(auctionContract).getAuctionId(_tokenId);

        // 고정가 판매인 경우
        if (auctionType == 3 || auctionType == 4) {
            // 고정가는 1회만 입찰할 수 있다.
            require(!_bidderHasABid(_tokenAddress, _tokenId, _bidder), "Bidder already bid");
        }

        // 경매 데이터 생성
        bytes32 bidId = _placeBid(
            _tokenAddress, 
            _tokenId,
            _price,
            _bidder,
            _duration,
            "",
            _name,
            _description,
            _bidImage
        );

        // 고정가 판매인 경우
        if (auctionType == 3 || auctionType == 4) {

            // price 고정가만큼 넣었는지 체크
            uint256 fixedPrice = IEGGVERSEAuction(auctionContract).getAuctionPrice(_tokenId);
            require(fixedPrice == _price, "Not correct fixed price");

            require(IEGGVERSEAuction(auctionContract).getAuctionPrice(_tokenId) == _price, "Not correct fixed price");
            address auctionOwner = IEGGVERSEAuction(auctionContract).ownerOf(_tokenId);

            if(auctionType == 3){ 
                // 일반인 경우 accept 까지 함 (order 생성됨)
                // auction NFT 이동(고정가 판매 완료/낙찰)
                IEGGVERSEAuction(auctionContract).safeTransferFrom(auctionOwner, address(this), _tokenId, _byte32ToBytes(bidId));
            }

            else if (auctionType == 4){
                _placeFixedBulkForKlaytn(_tokenAddress, _tokenId, _price, _bidder, bidId, auctionOwner);
            }
        }
    }

    function _placeFixedBulkForKlaytn(address _tokenAddress, uint256 _tokenId, uint256 _price, address _bidder, bytes32 bidId, address auctionOwner) internal{
        // --- bid 삭제 --- 
        uint256 bidIndex = bidIndexByBidId[bidId];

        // _getBid(address _tokenAddress, uint256 _tokenId, uint256 _index) 
        Bid memory bid = _getBid(_tokenAddress, _tokenId, bidIndex);

        // Check fingerprint if necessary
        _requireComposableERC721(_tokenAddress, _tokenId, bid.fingerprint);

        // 재구매 체크해야하므로 bid 삭제하지 않음
        // _deleteBid(_tokenAddress, _tokenId, bidIndex, _bidder, bidId);

        // ___ bid 삭제 ___

        // 수수료 계산
        uint256 saleShareAmount = 0;
        uint256 categoryId = IEGGVERSEAuction(auctionContract).getAuctionCategory(_tokenId);
        if (ownerCutPerMillion[categoryId] > 0) {
            // Calculate sale share
            saleShareAmount = _price.mul(ownerCutPerMillion[categoryId]).div(ONE_MILLION);
            // Transfer share amount to the bid conctract Owner
            // 수수료 전송은 백엔드에서 처리
        }

        // --- order 생성 ---

        // Delete bid references from contract storage
        Order memory order = Order({
            orderer: auctionOwner,
            bidder: bid.bidder,
            tokenAddress: _tokenAddress,
            tokenId: bid.tokenId,
            price: _price.sub(saleShareAmount), // 이러면 수수료는 판매자가 지불하는 것.
            expiresAt: block.timestamp + 14 days // 사실상 의미 없음
        });

        // finalize를 bidder(구매자)가 호출해야 함
        orders[_tokenAddress][_tokenId][bid.bidder] = order;

        // ___ order 생성 ___

        emit BidAccepted(
            bidId,
            _tokenAddress, // auction 주소
            _tokenId,
            bid.bidder, // 구매자
            auctionOwner, // 분할 경매 제시자(판매자)
            _price,
            saleShareAmount
        );

        // 마지막에 transfer 처리 (다른 경매와 동일하게 취급하려고) -> 이 때 pending 상태로(=낙찰 상태) 변화
        // bulk인 경우 - accept는 판매 개수가 다 팔렸을 경우만 transfer 함.
        // 재고 업데이트는 상단의 placeBid에서 처리됨.
        _check_final_stock(auctionOwner, _tokenId, bidId);
    }

    function _deleteBid(address _tokenAddress, uint256 _tokenId, uint256 bidIndex, address _bidder, bytes32 bidId) internal{
        delete bidsByToken[_tokenAddress][_tokenId][bidIndex];
        delete bidIndexByBidId[bidId];
        delete bidIdByTokenAndBidder[_tokenAddress][_tokenId][_bidder];

        // Reset bid counter to invalidate other bids placed for the token
        delete bidCounterByToken[_tokenAddress][_tokenId];
    }

    function _check_final_stock(address auctionOwner, uint256 _tokenId, bytes32 bidId) internal{
        uint256 stock = IEGGVERSEAuction(auctionContract).getAuctionStock(_tokenId);
        if(stock == 0){
            IEGGVERSEAuction(auctionContract).safeTransferFrom(auctionOwner, address(this), _tokenId, _byte32ToBytes(bidId));
        }
    }


    function placeFixedBid(
        bytes memory data,
        bytes memory sig,
        address _bidder,
        uint256 _duration,
        string memory _name,
        string memory _description,
        string memory _bidImage
    )
        public
        onlyAdmin
    {
        // 기존 placeBid와 동일
        require(_verify(data, sig, _bidder), "signature and _bidder data is not matching");
        ( address _tokenAddress, 
          uint256 _tokenId,
          uint256  _price ) = abi.decode(data, (address, uint256, uint256));


        // 고정가는 1회만 입찰할 수 있다.
        require(!_bidderHasABid(_tokenAddress, _tokenId, _bidder), "Bidder already bid");

        // 고정가 bulk 경매의 경우 auction.placeBid 호출을 통해 재고가 업데이트 됨.
        bytes32 bidId = _placeBid(
            _tokenAddress, 
            _tokenId,
            _price,
            _bidder,
            _duration,
            "",
            _name,
            _description,
            _bidImage
        );

        // 고정가 판매가 아닌 경우 revert
        uint8 auctionType = IEGGVERSEAuction(auctionContract).getAuctionId(_tokenId);
        require(auctionType == 3 || auctionType == 4, "Not fixed auction");

        // price 고정가만큼 넣었는지 체크
        uint256 fixedPrice = IEGGVERSEAuction(auctionContract).getAuctionPrice(_tokenId);
        require(fixedPrice == _price, "Not correct fixed price");

        address auctionOwner = IEGGVERSEAuction(auctionContract).ownerOf(_tokenId);

        if(auctionType == 3){ 
            // 일반인 경우 accept 까지 함 (order 생성됨)
            // auction NFT 이동(고정가 판매 완료/낙찰)
            IEGGVERSEAuction(auctionContract).safeTransferFrom(auctionOwner, address(this), _tokenId, _byte32ToBytes(bidId));
        }
        else if (auctionType == 4){
            // --- bid 삭제 --- 
            uint256 bidIndex = bidIndexByBidId[bidId];

            // _getBid(address _tokenAddress, uint256 _tokenId, uint256 _index) 
            Bid memory bid = _getBid(_tokenAddress, _tokenId, bidIndex);

            // Check fingerprint if necessary
            _requireComposableERC721(_tokenAddress, _tokenId, bid.fingerprint);

            // 재구매 체크해야하므로 bid 삭제하지 않음
            // delete bidsByToken[_tokenAddress][_tokenId][bidIndex];
            // delete bidIndexByBidId[bidId];
            // delete bidIdByTokenAndBidder[_tokenAddress][_tokenId][_bidder];

            // // Reset bid counter to invalidate other bids placed for the token
            // delete bidCounterByToken[_tokenAddress][_tokenId];

            // ___ bid 삭제 ___

            // 수수료 계산
            uint256 saleShareAmount = 0;
            uint256 categoryId = IEGGVERSEAuction(auctionContract).getAuctionCategory(_tokenId);
            if (ownerCutPerMillion[categoryId] > 0) {
                // Calculate sale share
                saleShareAmount = _price.mul(ownerCutPerMillion[categoryId]).div(ONE_MILLION);
                // Transfer share amount to the bid conctract Owner
                // 수수료 전송은 백엔드에서 처리
            }

            // --- order 생성 ---

            // Delete bid references from contract storage
            Order memory order = Order({
                orderer: auctionOwner,
                bidder: bid.bidder,
                tokenAddress: _tokenAddress,
                tokenId: bid.tokenId,
                price: _price.sub(saleShareAmount), // 이러면 수수료는 판매자가 지불하는 것.
                expiresAt: block.timestamp + 14 days // 사실상 의미 없음
            });

            // finalize를 bidder(구매자)가 호출해야 함
            orders[_tokenAddress][_tokenId][bid.bidder] = order;

            // ___ order 생성 ___

            emit BidAccepted(
                bidId,
                _tokenAddress, // auction 주소
                _tokenId,
                bid.bidder, // 구매자
                auctionOwner, // 분할 경매 제시자(판매자)
                _price,
                saleShareAmount
            );

            // 마지막에 transfer 처리 (다른 경매와 동일하게 취급하려고) -> 이 때 pending 상태로(=낙찰 상태) 변화
            // bulk인 경우 - accept는 판매 개수가 다 팔렸을 경우만 transfer 함.
            // 재고 업데이트는 상단의 placeBid에서 처리됨.
            uint256 stock = IEGGVERSEAuction(auctionContract).getAuctionStock(_tokenId);
            if(stock == 0){
                IEGGVERSEAuction(auctionContract).safeTransferFrom(auctionOwner, address(this), _tokenId, _byte32ToBytes(bidId));
            }
        }
    }

    function _byte32ToBytes(bytes32 x) internal pure returns (bytes memory b) {
        b = new bytes(32);
        assembly { mstore(add(b, 32), x) }
    }

    /**
    * @dev Place a bid for an ERC721 token via Admin delegate 
    * @param data - data (_tokenAddress, _tokenId, _price)
    * @param _bidder - bidder
    * @param _duration - uint256 of the duration in seconds for the bid
    * @param _name - string of bid name
    * @param _description - string of bid description
    */
    function placeBid(
        bytes memory data,
        bytes memory sig,
        address _bidder,
        uint256 _duration,
        string memory _name,
        string memory _description,
        string memory _bidImage
    )
        public
        onlyAdmin
    {
        require(_verify(data, sig, _bidder), "signature and _bidder data is not matching");
        ( address _tokenAddress, 
          uint256 _tokenId,
          uint256  _price ) = abi.decode(data, (address, uint256, uint256));
        _placeBid(
            _tokenAddress, 
            _tokenId,
            _price,
            _bidder,
            _duration,
            "",
            _name,
            _description,
            _bidImage
        );
    }

    /**
    * @dev Place a bid for an ERC721 token with fingerprint.
    * @notice Tokens can have multiple bids by different users.
    * Users can have only one bid per token.
    * If the user places a bid and has an active bid for that token,
    * the older one will be replaced with the new one.
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the token id
    * @param _price - uint256 of the price for the bid
    * @param _duration - uint256 of the duration in seconds for the bid
    * @param _fingerprint - bytes of ERC721 token fingerprint 
    * @param _name - string of bid name
    * @param _description - string of bid description
    */
    function _placeBid(
        address _tokenAddress, 
        uint256 _tokenId,
        uint256 _price,
        address _bidder,
        uint256 _duration,
        bytes memory _fingerprint,
        string memory _name,
        string memory _description,
        string memory _bidImage
    )
        private
        whenNotPaused()
        returns (bytes32)
    {
        // _requireERC721(_tokenAddress);

        require(_price > 0, "Price should be bigger than 0");

        require(
            _duration >= MIN_BID_DURATION, 
            "The bid should be last longer than a minute"
        );

        isTokenOwner(_tokenAddress, _tokenId, _bidder);
        uint256 expiresAt = block.timestamp.add(_duration);

        bytes32 bidId = keccak256(
            abi.encodePacked(
                block.timestamp,
                _bidder,
                _tokenAddress,
                _tokenId,
                _price,
                _duration,
                _fingerprint,
                _name,
                _description
            )
        );

        uint256 bidIndex;

        if (_bidderHasABid(_tokenAddress, _tokenId, _bidder)) {
            bytes32 oldBidId;
            (bidIndex, oldBidId,,,) = getBidByBidder(_tokenAddress, _tokenId, _bidder);
            
            // Delete old bid reference
            delete bidIndexByBidId[oldBidId];
        } else {
            // Use the bid counter to assign the index if there is not an active bid. 
            bidIndex = bidCounterByToken[_tokenAddress][_tokenId];  
            // Increase bid counter 
            bidCounterByToken[_tokenAddress][_tokenId]++;
        }

        // Set bid references
        bidIdByTokenAndBidder[_tokenAddress][_tokenId][_bidder] = bidId;
        bidIndexByBidId[bidId] = bidIndex;

        // Save Bid
        bidsByToken[_tokenAddress][_tokenId][bidIndex] = Bid({
            id: bidId,
            bidder: _bidder,
            tokenAddress: _tokenAddress,
            tokenId: _tokenId,
            price: _price,
            expiresAt: expiresAt,
            fingerprint: _fingerprint,
            name: _name,
            description: _description,
            bidImage: _bidImage
        });

        // auction 컨트랙트 데이터 등록용 함수 호출
        if(address(0) != auctionContract && _tokenAddress == auctionContract){

            // auction 상태 업데이트
            // uint256 _tokenId, address acceptBidder, uint256 acceptedAt, uint256 acceptedPrice
            IEGGVERSEAuction(auctionContract).placeBid(_tokenId, bidId, _bidder, _price);
        }

        emit BidCreated(
            bidId,
            _tokenAddress,
            _tokenId,
            _bidder,
            _price,
            expiresAt,
            _fingerprint,
            _name,
            _description,
            _bidImage
        );

        return bidId;
    }

    function isTokenOwner(address _tokenAddress, uint256 _tokenId, address sender)
    public view
    {
        ERC721Interface token = ERC721Interface(_tokenAddress);
        address tokenOwner = token.ownerOf(_tokenId);
        require(
            tokenOwner != address(0) && tokenOwner != sender,
            "The token should have an owner different from the sender"
        );
    }

    function placeNewBids(
        address _tokenAddress, 
        uint256 _tokenId,
        address[] memory bidders,
        uint256 _price
    ) external onlyAdmin {

        // 새로 입찰(임의로 입찰)
        for(uint256 i =0; i< bidders.length; i++){
            // bidder들로 placeBid 호출
            bytes32 bidId = _placeBid(
                _tokenAddress, 
                _tokenId,
                _price,
                bidders[i],
                15552000,
                "",
                "",
                "",
                ""
            );

            // 전부 채웠다면 끝냄. stock은 placeBid에서 업데이트된 상태.
            uint256 stock = IEGGVERSEAuction(auctionContract).getAuctionStock(_tokenId);
            if(stock == 0){
                break;
            }
        }
    }

    function addOrder(uint256 _tokenId, address bidder, uint256 price) external onlyAdmin {
        address auctionOwner = IEGGVERSEAuction(auctionContract).ownerOf(_tokenId);

        // Delete bid references from contract storage
        Order memory order = Order({
            orderer: auctionOwner,
            bidder: bidder,
            tokenAddress: auctionContract,
            tokenId: _tokenId,
            price: price, // 이러면 수수료는 판매자가 지불하는 것.
            expiresAt: block.timestamp + 14 days // 사실상 의미 없음
        });

        // finalize를 bidder(구매자)가 호출해야 함
        orders[auctionContract][_tokenId][bidder] = order;

    }

    function fixBids(
        uint256 _tokenId,
        address[] memory _bidders
    ) external onlyAdmin{
        address auctionOwner = IEGGVERSEAuction(auctionContract).ownerOf(_tokenId);

        // 마지막 bidId로 transfer 함. (값은 상관 없다.)
        bytes32 bidId;
        for(uint256 i =0; i< _bidders.length; i++){
            address _bidder = _bidders[i];

            uint256 bidIndex;
     
            // 정상 처리 됐던 건은 이미 삭제되어있고(과거 건에 한에서) order도 처리되어있음.
            if (_bidderHasABid(auctionContract, _tokenId, _bidder)) {
                (bidIndex, bidId,,,) = getBidByBidder(auctionContract, _tokenId, _bidder);
                // --- bid 삭제 --- 
                // _getBid(address _tokenAddress, uint256 _tokenId, uint256 _index) 
                Bid memory bid = _getBid(auctionContract, _tokenId, bidIndex);

                // Check fingerprint if necessary
                _requireComposableERC721(auctionContract, _tokenId, bid.fingerprint);

                // _deleteBid(auctionContract, _tokenId, bidIndex, _bidder, bidId);

                // ___ bid 삭제 ___

                // 수수료 계산
                uint256 saleShareAmount = 0;
                uint256 categoryId = IEGGVERSEAuction(auctionContract).getAuctionCategory(_tokenId);
                if (ownerCutPerMillion[categoryId] > 0) {
                    // Calculate sale share
                    saleShareAmount = bid.price.mul(ownerCutPerMillion[categoryId]).div(ONE_MILLION);
                    // Transfer share amount to the bid conctract Owner
                    // 수수료 전송은 백엔드에서 처리
                }

                // --- order 생성 ---

                // Delete bid references from contract storage
                Order memory order = Order({
                    orderer: auctionOwner,
                    bidder: bid.bidder,
                    tokenAddress: auctionContract,
                    tokenId: bid.tokenId,
                    price: bid.price.sub(saleShareAmount), // 이러면 수수료는 판매자가 지불하는 것.
                    expiresAt: block.timestamp + 14 days // 사실상 의미 없음
                });

                // finalize를 bidder(구매자)가 호출해야 함
                orders[auctionContract][_tokenId][bid.bidder] = order;

                // ___ order 생성 ___

                emit BidAccepted(
                    bidId,
                    auctionContract, // auction 주소
                    _tokenId,
                    bid.bidder, // 구매자
                    auctionOwner, // 분할 경매 제시자(판매자)
                    bid.price,
                    saleShareAmount
                );
            }
        }
       
        // bid accept 처리
        _check_final_stock(auctionOwner, _tokenId, bidId);
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
        whenNotPaused()
        returns (bytes4)
    {
        uint8 auctionType = IEGGVERSEAuction(auctionContract).getAuctionId(_tokenId);
        if (auctionType == 2) {

            // lowestPrice를 입력받되, 실제로 for문돌며 실행하면서 더 낮은 가격이 있었다면 revert 시킨다. (공격자는 손해만 보는 구조)
            uint256 lowestPrice;
            // solium-disable-next-line security/no-inline-assembly
            assembly {
                lowestPrice := mload(add(_data, 0x20))
            }

            bytes32[] memory bidlists;
            // solium-disable-next-line security/no-inline-assembly
            assembly {
                bidlists := add(_data, 0x60)
            }

            _bulkBidAccept(_from, _tokenId, bidlists, lowestPrice);
        }
        else if (auctionType == 4) { // bulk 고정가 
            // bid는 미리 삭제된다. 
            // order는 미리 생성되고 (placeBid 시점에)
            // auction 이벤트도 미리 생성된다 (placeBid 시점에)
            IEGGVERSEAuction(auctionContract).acceptFixedBulkAuction(_tokenId);
        }
        else{
            bytes32 bidId = _bytesToBytes32(_data);

            _accpetBid(_from, _tokenId, bidId, auctionType);
        }
        return ERC721_Received;
    }

    function acceptBidFromKlaytn(uint256 _tokenId, bytes memory _data) public onlyAdmin {
        IEGGVERSEAuction(auctionContract).safeTransferFrom(
            IEGGVERSEAuction(auctionContract).ownerOf(_tokenId),
            address(this),
            _tokenId,
            _data
        );
    }

    /**
    * @dev Accept a bid for an ERC721 token via Admin delegate 
    * 현재 사용하지 않지만 추후 fee 대납을 위해 사용
    */
    function accpetBid(
        bytes memory data,
        bytes memory sig,
        address _orderer
    )
        public
        onlyAdmin
    {
        require(_verify(data, sig, _orderer), "signature and _bidder data is not matching");
        ( uint256 _tokenId, bytes32 _bidId ) = abi.decode(data, (uint256, bytes32));
        IEGGVERSEAuction(auctionContract).safeTransferFrom(_orderer, address(this), _tokenId, _byte32ToBytes(_bidId));
    }

    function _accpetBid(
        address _from,
        uint256 _tokenId,
        bytes32 bidId,
        uint8 auctionType
    )
        internal
        whenNotPaused()
    {
        uint256 bidIndex = bidIndexByBidId[bidId];

        // _getBid(address _tokenAddress, uint256 _tokenId, uint256 _index) 
        Bid memory bid = _getBid(msg.sender, _tokenId, bidIndex);

        // Check if the bid is valid.
        require(
            // solium-disable-next-line operator-whitespace
            bid.id == bidId,
            "Invalid bid"
        );

        address bidder = bid.bidder;
        uint256 price = bid.price;
        
        // Check fingerprint if necessary
        _requireComposableERC721(msg.sender, _tokenId, bid.fingerprint);

        delete bidsByToken[msg.sender][_tokenId][bidIndex];
        delete bidIndexByBidId[bidId];
        delete bidIdByTokenAndBidder[msg.sender][_tokenId][bidder];

        // Reset bid counter to invalidate other bids placed for the token
        delete bidCounterByToken[msg.sender][_tokenId];

        // 수수료 계산
        uint256 saleShareAmount = 0;
        uint256 categoryId = IEGGVERSEAuction(auctionContract).getAuctionCategory(_tokenId);
        if (ownerCutPerMillion[categoryId] > 0) {
            // Calculate sale share
            saleShareAmount = price.mul(ownerCutPerMillion[categoryId]).div(ONE_MILLION);
            // Transfer share amount to the bid conctract Owner
            // 수수료 전송은 백엔드에서 처리
        }

        // Delete bid references from contract storage
        Order memory order = Order({
            orderer: _from, // 역경매 제시자(구매자) 
            bidder: bid.bidder, // 판매자
            tokenAddress: msg.sender,
            tokenId: bid.tokenId,
            price: price.sub(saleShareAmount), // 이러면 수수료는 판매자가 지불하는 것.
            expiresAt: block.timestamp + 14 days // tmp value
        });

        if(auctionType == 0) { // 역경매의 경우 finalize 를 역경매 제시자가 해야함. 따라서 key는 역경매 제시자.
            orders[msg.sender][_tokenId][_from] = order;
        }
        else{ // 일반 경매의 경우 finalize를 bidder(구매자)가 호출
            orders[msg.sender][_tokenId][bid.bidder] = order;
        }

        emit BidAccepted(
            bidId,
            msg.sender, // auction 주소
            _tokenId,
            bidder, // 판매자 // gql _bidder
            _from, // 역경매 제시자(구매자) // gql _seller
            price,
            saleShareAmount
        );

        // auction 컨트랙트 데이터 등록용 함수 호출
        if(address(0) != auctionContract && msg.sender == auctionContract){
            // auction 상태 업데이트
            // uint256 _tokenId, address acceptBidder, uint256 acceptedAt, uint256 acceptedPrice, bytes32 acceptedBidId, uint256 acceptedBidImage, string memory acceptedBidName, string memory acceptedBidDescription
            IEGGVERSEAuction(auctionContract).acceptBid(_tokenId, bidder, block.timestamp, price, bidId, bid.bidImage, bid.name, bid.description);
        }

    }

    function _bulkBidAccept(
        address _from,
        uint256 _tokenId,
        bytes32[] memory bidlists,
        uint256 lowestPrice
       ) internal {
        // bidlists length가 등록한 판매 개수보다 같거나 적은지 체크해야 함

        for(uint i = 0; i< bidlists.length; i++){
            bytes32 bidId = bidlists[i];
            uint256 bidIndex = bidIndexByBidId[bidId];

            // _getBid(address _tokenAddress, uint256 _tokenId, uint256 _index) 
            Bid memory bid = _getBid(msg.sender, _tokenId, bidIndex);

            // Check if the bid is valid.
            require(
                // solium-disable-next-line operator-whitespace
                bid.id == bidId,
                "Invalid bid"
            );

            address bidder = bid.bidder;
            uint256 price = lowestPrice;

            // 입력한 가격이 최소 가격이 아니었다면(악성 유저) revert 시킨다.
            require(price <= bid.price, "Wrong lowest price");
            
            // Check fingerprint if necessary
            _requireComposableERC721(msg.sender, _tokenId, bid.fingerprint);

            delete bidsByToken[msg.sender][_tokenId][bidIndex];
            delete bidIndexByBidId[bidId];
            delete bidIdByTokenAndBidder[msg.sender][_tokenId][bidder];

            uint256 saleShareAmount = 0;

            uint256 categoryId = IEGGVERSEAuction(auctionContract).getAuctionCategory(_tokenId);
            if (ownerCutPerMillion[categoryId] > 0) {
                // Calculate sale share
                saleShareAmount = price.mul(ownerCutPerMillion[categoryId]).div(ONE_MILLION);
                // 실제 수수료 전송은 백엔드에서 처리
            }

            // Delete bid references from contract storage
            Order memory order = Order({
                orderer: _from, // 역경매 제시자(구매자) 
                bidder: bid.bidder, // 판매자
                tokenAddress: msg.sender,
                tokenId: bid.tokenId,
                price: price.sub(saleShareAmount), // 이러면 수수료는 판매자가 지불하는 것.
                expiresAt: block.timestamp + 14 days // tmp value
            });

            // 분할 경매의 경우 일반경매와 마찬가지로 finalize를 bidder(구매자)가 호출
            orders[msg.sender][_tokenId][bid.bidder] = order;

            emit BidAccepted(
                bidId,
                msg.sender, // auction 주소
                _tokenId,
                bidder, // 구매자
                _from, // 분할 경매 제시자(판매자)
                price,
                saleShareAmount
            );

            // auction 컨트랙트 데이터 등록용 함수 호출
            if(address(0) != auctionContract && msg.sender == auctionContract){
                // auction 상태 업데이트
                // uint256 _tokenId, address acceptBidder, uint256 acceptedAt, uint256 acceptedPrice, bytes32 acceptedBidId, uint256 acceptedBidImage, string memory acceptedBidName, string memory acceptedBidDescription
                IEGGVERSEAuction(auctionContract).acceptBid(_tokenId, bidder, block.timestamp, price, bidId, bid.bidImage, bid.name, bid.description);
            }
        }

        // Reset bid counter to invalidate other bids placed for the token
        delete bidCounterByToken[msg.sender][_tokenId];
    }

    function getOrder(address _tokenAddress, uint256 _tokenId, address _address) public view returns (address, address, uint256){
        Order memory order = orders[_tokenAddress][_tokenId][_address];
        return (
            order.bidder,
            order.orderer,
            order.price
        );
    }

    function _finalizeOrder(address _tokenAddress, uint256 _tokenId, address _address, string memory cid) internal {

        Order memory order = orders[_tokenAddress][_tokenId][_address];
        uint8 auctionType = IEGGVERSEAuction(auctionContract).getAuctionId(_tokenId);
        require(
            (order.orderer == _address && auctionType == 0) ||
            (order.bidder == _address && auctionType != 0)
        );
        address bidder = order.bidder;
        uint256 certificateTokenId = ERC721Interface(_certificateAddress).mint(bidder, cid);

        // auction에 이벤트 보냄
        // auction 컨트랙트 데이터 등록용 함수 호출
        if(address(0) != auctionContract && _tokenAddress == auctionContract){
            // auction 상태 업데이트
            // uint256 _tokenId, uint256 _certificateTokenId
            IEGGVERSEAuction(auctionContract).finalizeOrder(_tokenId, certificateTokenId, _address);
        }

        // NFT 마켓인 경우 certificate를 burn 시킴 (NFT가 복사되는 현상 방지)
        // approve는 certificate mint에서 받음.
        if(IEGGVERSEAuction(auctionContract).getIsNftAuction(_tokenId) == true){
            ERC721Interface(_certificateAddress).burn(certificateTokenId);
        }

        delete orders[_tokenAddress][_tokenId][_address];
    }

    /**
    * @dev Finalize a order for an ERC721 token via Admin delegate 
    */
    function finalizeOrder(bytes memory data, bytes memory sig, address _orderer)
        public
        onlyAdmin
    {
        require(_verify(data, sig, _orderer), "signature and _bidder data is not matching");
        ( address _tokenAddress, uint256 _tokenId, string memory cid ) = abi.decode(data, (address, uint256, string));
        _finalizeOrder(_tokenAddress, _tokenId, _orderer, cid);

    }

    /**
    * @dev Finalize a order for an ERC721 token via Admin delegate 
    */
    function finalizeOrderFromKlaytn(address _tokenAddress, uint256 _tokenId, address _orderer, string memory cid)
        public
        onlyAdmin
    {
        _finalizeOrder(_tokenAddress, _tokenId, _orderer, cid);
    }


    function forceFinalizeOrder(address _tokenAddress, uint256 _tokenId, address _address, string memory cid) onlyOwner public {
        _finalizeOrder(_tokenAddress, _tokenId, _address, cid);
    }

    function forceCancelOrder(address _tokenAddress, uint256 _tokenId, address _address) onlyOwner public {
        Order memory order = orders[_tokenAddress][_tokenId][_address];

        address bidder = order.bidder;
        address orderer = order.orderer;

        require(bidder != address(0) && orderer != address(0), "Order not exist");

        // auction에 이벤트 보냄
        // auction 컨트랙트 데이터 등록용 함수 호출
        if(address(0) != auctionContract && _tokenAddress == auctionContract){
            // auction 상태 업데이트
            // uint256 _tokenId
            IEGGVERSEAuction(auctionContract).cancelOrder(_tokenId);
        }

        delete orders[_tokenAddress][_tokenId][_address];
    }

    function setCertificateAddress(address _tokenAddress) onlyOwner public {
        _certificateAddress = _tokenAddress;
    }
    /**
    * @dev Remove expired bids
    * @param _tokenAddresses - address[] of the ERC721 tokens
    * @param _tokenIds - uint256[] of the token ids
    * @param _bidders - address[] of the bidders
    */
    function removeExpiredBids(address[] memory _tokenAddresses, uint256[] memory _tokenIds, address[] memory _bidders)
    public 
    {
        uint256 loopLength = _tokenAddresses.length;

        require(loopLength == _tokenIds.length, "Parameter arrays should have the same length");
        require(loopLength == _bidders.length, "Parameter arrays should have the same length");

        for (uint256 i = 0; i < loopLength; i++) {
            _removeExpiredBid(_tokenAddresses[i], _tokenIds[i], _bidders[i]);
        }
    }
    
    /**
    * @dev Remove expired bid
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the token id
    * @param _bidder - address of the bidder
    */
    function _removeExpiredBid(address _tokenAddress, uint256 _tokenId, address _bidder)
    internal 
    {
        (uint256 bidIndex, bytes32 bidId,,,uint256 expiresAt) = getBidByBidder(
            _tokenAddress, 
            _tokenId,
            _bidder
        );
        
        require(expiresAt < block.timestamp, "The bid to remove should be expired");

        _cancelBid(
            bidIndex, 
            bidId, 
            _tokenAddress, 
            _tokenId, 
            _bidder
        );
    }

    /**
    * @dev Cancel a bid for an ERC721 token
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the token id
    */
    function cancelBid(address _tokenAddress, uint256 _tokenId) public whenNotPaused() {
        // Get active bid
        (uint256 bidIndex, bytes32 bidId,,,) = getBidByBidder(
            _tokenAddress, 
            _tokenId,
            msg.sender
        );

        _cancelBid(
            bidIndex, 
            bidId, 
            _tokenAddress, 
            _tokenId, 
            msg.sender
        );
    }

    /**
    * @dev Cancel a order for an ERC721 token via Admin delegate 
    */
    function cancelBid(bytes memory data, bytes memory sig, address _orderer)
        public
        onlyAdmin
    {
        require(_verify(data, sig, _orderer), "signature and _bidder data is not matching");
        ( address _tokenAddress, uint256 _tokenId ) = abi.decode(data, (address, uint256));
        
        (uint256 bidIndex, bytes32 bidId,,,) = getBidByBidder(
            _tokenAddress, 
            _tokenId,
            _orderer
        );

        _cancelBid(
            bidIndex, 
            bidId, 
            _tokenAddress, 
            _tokenId, 
            _orderer
        );

    }

    /**
    * @dev Cancel a bid for an ERC721 token
    * @param _bidIndex - uint256 of the index of the bid
    * @param _bidId - bytes32 of the bid id
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the token id
    * @param _bidder - address of the bidder
    */
    function _cancelBid(
        uint256 _bidIndex,
        bytes32 _bidId, 
        address _tokenAddress,
        uint256 _tokenId, 
        address _bidder
    ) 
        internal 
    {
        // Delete bid references
        delete bidIndexByBidId[_bidId];
        delete bidIdByTokenAndBidder[_tokenAddress][_tokenId][_bidder];
        
        // Check if the bid is at the end of the mapping
        uint256 lastBidIndex = bidCounterByToken[_tokenAddress][_tokenId].sub(1);
        if (lastBidIndex != _bidIndex) {
            // Move last bid to the removed place
            Bid storage lastBid = bidsByToken[_tokenAddress][_tokenId][lastBidIndex];
            bidsByToken[_tokenAddress][_tokenId][_bidIndex] = lastBid;
            bidIndexByBidId[lastBid.id] = _bidIndex;
        }
        
        // Delete empty index
        delete bidsByToken[_tokenAddress][_tokenId][lastBidIndex];

        // Decrease bids counter
        bidCounterByToken[_tokenAddress][_tokenId]--;

        // emit BidCancelled event
        emit BidCancelled(
            _bidId,
            _tokenAddress,
            _tokenId,
            _bidder
        );
    }

    /**
    * @dev Check if the bidder has a bid for an specific token.
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the token id
    * @param _bidder - address of the bidder
    * @return bool whether the bidder has an active bid
    */
    function _bidderHasABid(address _tokenAddress, uint256 _tokenId, address _bidder) 
        internal
        view 
        returns (bool)
    {
        bytes32 bidId = bidIdByTokenAndBidder[_tokenAddress][_tokenId][_bidder];
        uint256 bidIndex = bidIndexByBidId[bidId];
        // Bid index should be inside bounds
        if (bidIndex < bidCounterByToken[_tokenAddress][_tokenId]) {
            Bid memory bid = bidsByToken[_tokenAddress][_tokenId][bidIndex];
            return bid.bidder == _bidder;
        }
        return false;
    }

    /**
    * @dev Get the active bid id and index by a bidder and an specific token. 
    * @notice If the bidder has not a valid bid, the transaction will be reverted.
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the token id
    * @param _bidder - address of the bidder
    * @return bidIndex - uint256 of the bid index to be used within bidsByToken mapping
    * @return bidId - bytes32 of the bid id
    * @return bidder - address of the bidder address
    * @return price - uint256 of the bid price
    * @return expiresAt - uint256 of the expiration time
    */
    function getBidByBidder(address _tokenAddress, uint256 _tokenId, address _bidder) 
        public
        view 
        returns (
            uint256 bidIndex, 
            bytes32 bidId, 
            address bidder, 
            uint256 price, 
            uint256 expiresAt
        ) 
    {
        bidId = bidIdByTokenAndBidder[_tokenAddress][_tokenId][_bidder];
        bidIndex = bidIndexByBidId[bidId];
        (bidId, bidder, price, expiresAt) = getBidByToken(_tokenAddress, _tokenId, bidIndex);
        if (_bidder != bidder) {
            revert("Bidder has not an active bid for this token");
        }
    }

    function getBidByToken(address _tokenAddress, uint256 _tokenId, uint256 _index) 
        public 
        view
        returns (bytes32, address, uint256, uint256) 
    {
        
        Bid memory bid = _getBid(_tokenAddress, _tokenId, _index);
        return (
            bid.id,
            bid.bidder,
            bid.price,
            bid.expiresAt
        );
    }

    /**
    * @dev Get the active bid id and index by a bidder and an specific token. 
    * @notice If the index is not valid, it will revert.
    * @param _tokenAddress - address of the ERC721 token
    * @param _tokenId - uint256 of the index
    * @param _index - uint256 of the index
    * @return Bid
    */
    function _getBid(address _tokenAddress, uint256 _tokenId, uint256 _index) 
        internal 
        view 
        returns (Bid memory)
    {
        require(_index < bidCounterByToken[_tokenAddress][_tokenId], "Invalid index");
        return bidsByToken[_tokenAddress][_tokenId][_index];
    }

    /**
    * @dev Sets the share cut for the owner of the contract that's
    * charged to the seller on a successful sale
    * @param _ownerCutPerMillion - Share amount, from 0 to 999,999
    */
    function setOwnerCutPerMillion(uint256 categoryId, uint256 _ownerCutPerMillion) external onlyOwner {
        require(_ownerCutPerMillion < ONE_MILLION, "The owner cut should be between 0 and 999,999");

        ownerCutPerMillion[categoryId] = _ownerCutPerMillion;
        emit ChangedOwnerCutPerMillion(categoryId, _ownerCutPerMillion);
    }

    /**
    * @dev Convert bytes to bytes32
    * @param _data - bytes
    * @return bytes32
    */
    function _bytesToBytes32(bytes memory _data) internal pure returns (bytes32) {
        require(_data.length == 32, "The data should be 32 bytes length");

        bytes32 bidId;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            bidId := mload(add(_data, 0x20))
        }
        return bidId;
    }

    /**
    * @dev Check if the token has a valid ERC721 implementation
    * @param _tokenAddress - address of the token
    */
    function _requireERC721(address _tokenAddress) internal view {
        require(_tokenAddress.isContract(), "Token should be a contract");

        ERC721Interface token = ERC721Interface(_tokenAddress);
        require(
            token.supportsInterface(ERC721_Interface),
            "Token has an invalid ERC721 implementation"
        );
    }

    /**
    * @dev Check if the token has a valid Composable ERC721 implementation
    * And its fingerprint is valid
    * @param _tokenAddress - address of the token
    * @param _tokenId - uint256 of the index
    * @param _fingerprint - bytes of the fingerprint
    */
    function _requireComposableERC721(
        address _tokenAddress,
        uint256 _tokenId,
        bytes memory _fingerprint
    )
        internal
        view
    {
        ERC721Verifiable composableToken = ERC721Verifiable(_tokenAddress);
        if (composableToken.supportsInterface(ERC721Composable_ValidateFingerprint)) {
            require(
                composableToken.verifyFingerprint(_tokenId, _fingerprint),
                "Token fingerprint is not valid"
            );
        }
    }

    /**
    * @dev set bid Contract address
    */
    function setAuctionContract(address _auctionContract) external onlyOwner{
        auctionContract = _auctionContract;
    }

    /**
    * @dev certificate의 owner는 bid 컨트랙트로 설정된다. bid 컨트랙트를 변경할 때 이전 certifiate 컨트랙트를 그대로 사용하기 위해 이 함수를 호출한다. 
    */
    function transferCertificateOwnership(address newBidContract) external onlyOwner {
        CertificateInterface(_certificateAddress).transferOwnership(newBidContract);
    }

    function _verify(bytes memory data, bytes memory sig, address account) public pure returns (bool) {
        bytes32 dataHash = keccak256(data);
        bytes32 _ethSignedMessageHash = ECDSAUpgradeable.toEthSignedMessageHash(dataHash);
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(sig);
        return ecrecover(_ethSignedMessageHash, v, r, s) == account;
    }

   function splitSignature(bytes memory sig)
        public
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        require(sig.length == 65, "invalid signature length");

        assembly {
            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }

        // implicitly return (r, s, v)
    }

    modifier onlyAdmin() {
        require(adminAddress == _msgSender(), "Ownable: caller is not the escrow");
        _;
    }

    /**
     * @dev set bid Contract address
     */
    function setAdmin(address _admin) external onlyOwner{
        adminAddress = _admin;
    }
}

interface IEGGVERSEAuction {
    function acceptBid(
        uint256 _tokenId,
        address acceptBidder,
        uint256 acceptedAt,
        uint256 acceptedPrice,
        bytes32 acceptedBidId,
        string memory acceptedBidImage,
        string memory acceptedBidName,
        string memory acceptedBidDescription
    ) external;
    function acceptFixedBulkAuction (uint256 _tokenId) external;
    function finalizeOrder(uint256 _tokenId, uint256 _certificateTokenId, address _address) external;
    function cancelOrder(uint256 _tokenId) external;
    function placeBid(uint256 _tokenId, bytes32 bidId, address bidder, uint256 price) external;
    function getAuctionPrice(uint256 _tokenId) external returns (uint256);
    function getAuctionStock(uint256 _tokenId) external returns (uint256);
    function getAuctionCategory(uint256 _auctionType) external returns (uint256);
    function getAuctionId(uint256 _tokenId) external returns (uint8);
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data) external;
    function ownerOf(uint256 _tokenId) external returns (address);
    function getIsNftAuction(uint256 _tokenId) external view returns (bool);
}