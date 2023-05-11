// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

/**
 * @title Interface for contracts conforming to ERC-721
 */
interface ERC721Interface {
    function ownerOf(uint256 _tokenId) external view returns (address _owner);
    function transferFrom(address _from, address _to, uint256 _tokenId) external;
    function supportsInterface(bytes4) external view returns (bool);
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function mint(address _to, string calldata _tokenURI) external returns (uint256);
}


contract EGGVERSEAuction is Initializable, ERC721EnumerableUpgradeable, OwnableUpgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeMathUpgradeable for uint256;
    using ECDSAUpgradeable for bytes32;

    bytes4 public constant ERC721_Received = 0x150b7a02;

    // Map the number of tokens per auctionId
    mapping(uint8 => uint256) public auctionCount;

    // Map the number of tokens burnt per auctionId
    mapping(uint8 => uint256) public auctionBurnCount;

    enum Status{ OPEN, PENDING, SUCCESS, FAIL, CANCEL } // burn은 상태 없음 상태 맵에서도 삭제됨
    mapping(uint256 => Status) public auctionStatus;

    // Used for generating the tokenId of new NFT minted
    CountersUpgradeable.Counter private _tokenIds;

    // Map the auctionId for each tokenId
    mapping(uint256 => uint8) private auctionIds;

    // Map the auctionName for a tokenId
    mapping(uint8 => string) private auctionNames;
    mapping(uint256 => uint256) private auctionCategory;

    event AuctionCreated(uint256 _tokenId, uint8 _auctionType, string _tokenURI, address _proposer);
    event AuctionAccepted(
        uint256 _tokenId,
        address acceptBidder,
        uint256 acceptedAt,
        uint256 acceptedPrice,
        bytes32 acceptedBidId,
        string acceptedBidImage,
        string acceptedBidName,
        string acceptedBidDescription
    );
    event FixedBulkAuctionAccepted(uint256 _tokenId);
    event AuctionSetStock(uint256 _tokenId, uint256 _stock);
    event AuctionFinalized(uint256 _tokenId, uint256 _certificateTokenId, address _address);
    event AuctionCanceled(uint256 _tokenId);
    event BidPlaced(uint256 _tokenId, bytes32 bidId, address bidder, uint256 price);
    event AuctionSetCategory(uint256 _tokenId, uint256 _auctionCategory);
    event AuctionSetNftMarket(uint256 _tokenId, address _tokenAddress, uint256 _id);
    // 판매한 NFT 정보, 구매자 정보
    event AuctionNFtMarketSold(uint256 _tokenId, address _tokenAddress, uint256 chainId, address buyer);

    // 경매를 burn 시켰을 시 NFT 마켓인 경우 이 이벤트를 발생. 이것을 잡아 환불시켜줌
    event AuctionNFtMarketBurned(uint256 _tokenId, address _tokenAddress, uint256 chainId, address owner);

    event BidFirstAuctionCreated(uint256 _tokenId);

    address public bidContract;

    string public baseURI;

    // Optional mapping for token URIs
    mapping(uint256 => string) private _tokenURIs;

    // expire dates timestamps
    mapping(uint256 => uint256) private auctionExpiresAt;

    // 고정가/시작가 
    mapping(uint256 => uint256) private auctionPrice;

    // bulk 재고
    mapping(uint256 => uint256) private auctionStock;

    mapping(uint256 => address) private nftAuctionAddress;
    mapping(uint256 => uint256) private nftAuctionId;
    mapping(uint256 => bool) private isNftAuction;

    // bulk 재고 (고정)
    mapping(uint256 => uint256) private originAuctionStock;

    mapping(uint256 => uint256) private nftChian; // NFT 마켓일 시 사용하는 체인 번호

    mapping(uint256 => bool) public isBidFirstAuction;

    function initialize(string memory baseUri) public initializer {
        __ERC721_init("Eggverse Auction", "EGGA");
        __ERC721Enumerable_init();
        __Ownable_init();
        _setBaseURI(baseUri);
    }

    function _setBaseURI(string memory uri) internal {
        baseURI = uri;
    }
    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721URIStorage: URI query for nonexistent token");

        string memory _tokenURI = _tokenURIs[tokenId];
        string memory base = _baseURI();

        // If there is no base URI, return the token URI.
        if (bytes(base).length == 0) {
            return _tokenURI;
        }
        // If both are set, concatenate the baseURI and tokenURI (via abi.encodePacked).
        if (bytes(_tokenURI).length > 0) {
            return string(abi.encodePacked(base, _tokenURI));
        }

        return super.tokenURI(tokenId);
    }

    function getNftChianId(uint256 marketId) external view returns (uint256){
        return nftChian[marketId];
    }

    /**
     * @dev Get auctionId for a specific tokenId.
     */
    function getAuctionId(uint256 _tokenId) external view returns (uint8) {
        return auctionIds[_tokenId];
    }

    /**
     * @dev Get the associated auctionName for a specific auctionId.
     */
    function getAuctionName(uint8 _auctionType)
        external
        view
        returns (string memory)
    {
        return auctionNames[_auctionType];
    }

    function getIsNftAuction(uint256 _tokenId) public view returns (bool) {
        return isNftAuction[_tokenId];
    }

    function getNftAuctionAddress(uint256 _tokenId) public view returns (address) {
        return nftAuctionAddress[_tokenId];
    }

    function getNftAuctionId(uint256 _tokenId) public view returns (uint256) {
        return nftAuctionId[_tokenId];
    }

    /**
     * @dev Get the associated auctionName for a unique tokenId.
     */
    function getAuctionNameOfTokenId(uint256 _tokenId)
        external
        view
        returns (string memory)
    {
        uint8 auctionId = auctionIds[_tokenId];
        return auctionNames[auctionId];
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
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
        uint256 chainId // NFT 판매시 NFT 가 존재하는 체인 번호. 0 = polygon, 1 = ether, 2 = klaytn
    ) external /* onlyOwner */ returns (uint256) {
        // 프론트, 컨트랙트 타임스탬프 오차를 보정하기 위해 앞뒤 5분 여유 둠
        // require(expiresAt >= block.timestamp - 5 minutes && expiresAt <= block.timestamp + 30 days + 5 minutes, "Invalid auction duration");

        uint256 newId = _tokenIds.current();
        _tokenIds.increment();
        auctionIds[newId] = _auctionType;
        auctionCount[_auctionType] = auctionCount[_auctionType].add(1);
        _mint(_to, newId);
        _setTokenURI(newId, _tokenURI);
        
        auctionStatus[newId] = Status.OPEN;
        auctionCategory[newId] = _auctionCategory;
        auctionExpiresAt[newId] = expiresAt;
        auctionPrice[newId] = _price;
        auctionStock[newId] = _stock;
        originAuctionStock[newId] = _stock;


        // NFT 판매 경매인 경우
        if(_tokenAddress != address(0)){
            _openNFTMarket(_to, _tokenAddress, _id, _auctionType, newId, chainId);
        }

        // make bid contract control NFT (automatic transfer auction)
        _approve(bidContract, newId);

        emit AuctionCreated(newId, _auctionType, _tokenURI, _to);

        // 나중에 추가된 변수 알림
        emit AuctionSetCategory(newId, _auctionCategory);

        // 나중에 추가된 변수 알림
        // bulk auction일 때만 의미가 있음.
        emit AuctionSetStock(newId, _stock);

        return newId;
    }

    function mintBidFirstAuction(
        address _to,
        string memory _tokenURI,
        uint8 _auctionType,
        uint256 _auctionCategory,
        uint256 expiresAt, // timestamp
        uint256 _price, // 고정가, 시작가
        uint256 _stock, // bulk 경매 재고
        address _tokenAddress, // NFT 판매시 NFT 주소
        uint256 _id, // NFT 판매시 NFT 토큰 id
        uint256 chainId // NFT 판매시 NFT 가 존재하는 체인 번호. 0 = polygon, 1 = ether, 2 = klaytn
    ) public onlyOwner {
        // mint와 동일. _openNFTMarket 호출하지 않기 위해 코드 복붙함.

        uint256 newId = _tokenIds.current();
        _tokenIds.increment();
        auctionIds[newId] = _auctionType;
        auctionCount[_auctionType] = auctionCount[_auctionType].add(1);
        _mint(_to, newId);
        _setTokenURI(newId, _tokenURI);
        
        auctionStatus[newId] = Status.OPEN;
        auctionCategory[newId] = _auctionCategory;
        auctionExpiresAt[newId] = expiresAt;
        auctionPrice[newId] = _price;
        auctionStock[newId] = _stock;
        originAuctionStock[newId] = _stock;

        // make bid contract control NFT (automatic transfer auction)
        _approve(bidContract, newId);

        emit AuctionCreated(newId, _auctionType, _tokenURI, _to);

        // 나중에 추가된 변수 알림
        emit AuctionSetCategory(newId, _auctionCategory);

        // 나중에 추가된 변수 알림
        // bulk auction일 때만 의미가 있음.
        emit AuctionSetStock(newId, _stock);


        // update NFT info
        nftAuctionAddress[newId] = _tokenAddress;
        nftAuctionId[newId] = _id;
        isNftAuction[newId] = true;
        nftChian[newId] = chainId;

        emit AuctionSetNftMarket(newId, _tokenAddress, _id);

        // bidFirst 표시
        isBidFirstAuction[newId] = true;

        emit BidFirstAuctionCreated(newId);
    }


    function _openNFTMarket(address _seller, address _tokenAddress, uint256 _id, uint8 _auctionType, uint256 newId, uint256 chainId) internal {
        // 일반 경매, 고정가 일반 경매만 허용
        require(_auctionType == 1 || _auctionType == 3, "Only auction/fixed auction can sell NFT");

        // 판매할 NFT를 auction으로 옮김
        // 미리 approve 되어있어야 함
        if(chainId == block.chainid){
            // _requireERC721(_tokenAddress);
            // polygon 외의 체인에 있는 NFT는 해당 체인의 에스크로에 있음
            ERC721Interface(_tokenAddress).transferFrom(_seller, address(this), _id);
        }

        // update NFT info
        nftAuctionAddress[newId] = _tokenAddress;
        nftAuctionId[newId] = _id;
        isNftAuction[newId] = true;
        nftChian[newId] = chainId;

        emit AuctionSetNftMarket(newId, _tokenAddress, _id);
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

    /**
    * @dev Place a bid for an ERC721 token via Admin delegate 
    */
    /*
    function mint(
        string memory data,
        address _orderer
    )
        public
        onlyAdmin
    {
        require(_verify(data, _bidder), "signature and _bidder data is not matching");
        ( string memory _tokenURI,
        uint8 _auctionType,
        uint256 _auctionCategory,
        uint256 expiresAt ) = abi.decode(data, (string, uint8, uint256, uint256));

        // 경매 진행 시간: 최소 1일, 최대 30일 후
        // 프론트, 컨트랙트 타임스탬프 오차를 보정하기 위해 앞뒤 5분 여유 둠
        require(expiresAt >= block.timestamp + 1 days - 5 minutes && expiresAt <= block.timestamp + 30 days + 5 minutes, "Invalid auction duration");

        uint256 newId = _tokenIds.current();
        _tokenIds.increment();
        auctionIds[newId] = _auctionType;
        auctionCount[_auctionType] = auctionCount[_auctionType].add(1);
        _mint(_orderer, newId);
        _setTokenURI(newId, _tokenURI);
        
        auctionStatus[newId] = Status.OPEN;
        auctionCategory[newId] = _auctionCategory;
        auctionExpiresAt[newId] = expiresAt;

        // make bid contract control NFT (automatic transfer auction)
        _approve(bidContract, newId);

        emit AuctionCreated(newId, _auctionType, _tokenURI, _to);

        // 나중에 추가된 변수 알림
        emit AuctionSetCategory(newId, _auctionCategory);

        return newId;
    }
    */

    /**
     * @dev Sets `_tokenURI` as the tokenURI of `tokenId`.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function _setTokenURI(uint256 tokenId, string memory _tokenURI) internal virtual {
        require(_exists(tokenId), "ERC721URIStorage: URI set of nonexistent token");
        _tokenURIs[tokenId] = _tokenURI;
    }


    /**
     * @dev Set a unique name for each auctionId. It is supposed to be called once.
     */
    function setAuctionName(uint8 _auctionType, string calldata _name)
        external
        onlyOwner
    {
        auctionNames[_auctionType] = _name;
    }

    /**
     * @dev Burn a NFT token.
     */
    function burn(uint256 _tokenId) external {
        // 이미 burn된 토큰은 더이상 owner일 수 없으므로, 걸러짐
        address _owner = ownerOf(_tokenId);
        require(msg.sender == _owner || msg.sender == owner(), "ERC721: caller is not token owner");

        // enum 첫번째가 open이므로 상태값이 0이지만, 위의 owner 체크에서 걸러진다.
        // 존재하지 않는 tokenId의 디폴트 상태값이 0이더라도 owner일 수 없기때문에 Ok.
        // 이미 낙찰한 경매는 삭제할 수 없음
        // -> 아니 애초에 낙찰 하면 auction NFT 소유권이 bid 컨트랙트로 넘어가서 안전함....
        require(auctionStatus[_tokenId] == Status.OPEN, "ERC721: auction is not open");
        require(originAuctionStock[_tokenId] == auctionStock[_tokenId], "product already sold, cannot close");
 
        uint8 auctionIdBurnt = auctionIds[_tokenId];
        auctionCount[auctionIdBurnt] = auctionCount[auctionIdBurnt].sub(1);
        auctionBurnCount[auctionIdBurnt] = auctionBurnCount[auctionIdBurnt].add(1);

        

        // NFT 경매인 경우 (폴리곤의 NFT일 때만)
        if(isNftAuction[_tokenId] && nftChian[_tokenId] == block.chainid){
            // bidfirst auction이 아니거나, bidfirst auction이면서 NFT 주인(경매주인)이 NFT를 auction에 넣어둔 경우
            if(
                !isBidFirstAuction[_tokenId]
                || (isBidFirstAuction[_tokenId] && ERC721Interface(nftAuctionAddress[_tokenId]).ownerOf(nftAuctionId[_tokenId]) == address(this))
            ){
                // 다시 주인에게 돌려줌
                // 경매 마감까지 안 팔리면? -> 알아서 경매 취소해라..
                ERC721Interface(nftAuctionAddress[_tokenId]).transferFrom(address(this), _owner, nftAuctionId[_tokenId]);
            }
        }
        else if (isNftAuction[_tokenId]){
            // 다른 체인의 NFT 경매인 경우
            // 이벤트를 발생시킴. 백엔드에서 잡아서 NFT를 돌려준다. 
            emit AuctionNFtMarketBurned(nftAuctionId[_tokenId], nftAuctionAddress[_tokenId], nftChian[_tokenId], _owner);
        }

        // 상태맵에서도 삭제
        delete auctionStatus[_tokenId];

        _burn(_tokenId);
    }

    function getAuctionPrice(uint256 _auctionId) external view returns (uint256) {
        return auctionPrice[_auctionId];
    }

    function getAuctionStock(uint256 _auctionId) external view returns (uint256) {
        return auctionStock[_auctionId];
    }

    function getAuctionCategory(uint256 _auctionId) external view returns (uint256) {
        return auctionCategory[_auctionId];
    }

    function getAuctionExpiresAt(uint256 _tokenId) external view returns (uint256) {
        return auctionExpiresAt[_tokenId];
    }

    /**
     * @dev Destroys `tokenId`.
     * The approval is cleared when the token is burned.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     *
     * Emits a {Transfer} event.
     */
    function _burn(uint256 tokenId) internal virtual override {
        super._burn(tokenId);

        if (bytes(_tokenURIs[tokenId]).length != 0) {
            delete _tokenURIs[tokenId];
        }
    }


    /**
     * @dev make event for subgraph
     */
    function acceptBid(
        uint256 _tokenId,
        address acceptBidder,
        uint256 acceptedAt,
        uint256 acceptedPrice,
        bytes32 acceptedBidId,
        string memory acceptedBidImage,
        string memory acceptedBidName,
        string memory acceptedBidDescription
    ) external onlyBid {
        // 낙찰 제한 여부는 알 수 없으므로 일단 막지 않았음
        // require(auctionExpiresAt[_tokenId] > block.timestamp, "Auction is expired");

        auctionStatus[_tokenId] = Status.PENDING;
        emit AuctionAccepted(_tokenId, acceptBidder, acceptedAt, acceptedPrice, acceptedBidId, acceptedBidImage, acceptedBidName, acceptedBidDescription);
    }

    function acceptFixedBulkAuction(uint256 _tokenId) external onlyBid {
        // auction NFT를 BID로 옮겨서 낙찰 로직 호출을 통해 호출됨
        auctionStatus[_tokenId] = Status.PENDING;
        emit FixedBulkAuctionAccepted(_tokenId);
    }

    /**
     * @dev make event for subgraph
     */
    function finalizeOrder(uint256 _tokenId, uint256 _certificateTokenId, address _address) external onlyBid {
        auctionStatus[_tokenId] = Status.SUCCESS;
        emit AuctionFinalized(_tokenId, _certificateTokenId, _address);

        // NFT 마켓인 경우 NFT를 보내준다. (폴리곤의 NFT일 때만)
        if(isNftAuction[_tokenId] == true && (auctionIds[_tokenId] == 1 || auctionIds[_tokenId] == 3)){
            if(nftChian[_tokenId] == block.chainid){
                ERC721Interface(nftAuctionAddress[_tokenId]).transferFrom(address(this), _address, nftAuctionId[_tokenId]);
            }
            
            // 다른 체인인 경우 이 이벤트 잡아서 보내줘야 함
            emit AuctionNFtMarketSold(nftAuctionId[_tokenId], nftAuctionAddress[_tokenId], nftChian[_tokenId], _address);
        }
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
        return ERC721_Received;
    }


    /**
     * @dev make event for subgraph
     */
    function cancelOrder(uint256 _tokenId) external onlyBid {
        auctionStatus[_tokenId] = Status.CANCEL;
        emit AuctionCanceled(_tokenId);
    }

    /**
     * @dev make event for subgraph
     */
    function placeBid(uint256 _tokenId, bytes32 bidId, address bidder, uint256 price) external onlyBid {

        // 경매 마감 후 입찰 받지 않음
        // require(auctionExpiresAt[_tokenId] > block.timestamp, "Auction is expired");

        // 고정가 bulk 판매의 경우 재고 업데이트
        if(auctionIds[_tokenId] == 4){
            // 재고 업데이트
            require(auctionStock[_tokenId] > 0, "Fixed bulk auction stock not enough");
            auctionStock[_tokenId] = auctionStock[_tokenId] -1;

            // PENDING으로 옮기지는 않는다.. 재고가 0이 되면 auction이 pending(=낙찰) 상태가 된다.
            // 상태 업데이트 - 낙찰된 것과 유사한 상태가 된다. auction NFT가 bid에 없다는 점이 차이점.
            emit AuctionSetStock(_tokenId, auctionStock[_tokenId]);
            emit AuctionAccepted(_tokenId, bidder, block.timestamp, price, bidId, "", "", "");
        }

        emit BidPlaced(_tokenId, bidId, bidder, price);
    }

    modifier onlyBid() {
        require(bidContract == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev set bid Contract address
     */
    function setBidContract(address _bidContract) external onlyOwner{
        bidContract = _bidContract;
    }

    // function _verify(bytes memory data, bytes memory sig, address account) public pure returns (bool) {
    //     bytes32 _ethSignedMessageHash = ECDSAUpgradeable.toEthSignedMessageHash(data);
    //     (bytes32 r, bytes32 s, uint8 v) = splitSignature(sig);
    //     return ecrecover(_ethSignedMessageHash, v, r, s) == account;
    // }

    // function splitSignature(bytes memory sig)
    //     public
    //     pure
    //     returns (
    //         bytes32 r,
    //         bytes32 s,
    //         uint8 v
    //     )
    // {
    //     require(sig.length == 65, "invalid signature length");

    //     assembly {
    //         /*
    //         First 32 bytes stores the length of the signature

    //         add(sig, 32) = pointer of sig + 32
    //         effectively, skips first 32 bytes of signature

    //         mload(p) loads next 32 bytes starting at the memory address p into memory
    //         */

    //         // first 32 bytes, after the length prefix
    //         r := mload(add(sig, 32))
    //         // second 32 bytes
    //         s := mload(add(sig, 64))
    //         // final byte (first byte of the next 32 bytes)
    //         v := byte(0, mload(add(sig, 96)))
    //     }

    //     // implicitly return (r, s, v)
    // }
}