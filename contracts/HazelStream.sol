// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title HazelStream
 * @notice Saniyelik lineer akış. Gönderen, token'ı önceden kontrata kilitler.
 * Alıcı istediği zaman claim ile biriken tutarı çeker.
 * Basit, pull-based, tek-para-birimli akış.
 */
contract HazelStream is Ownable {
    struct Stream {
        address sender;
        address recipient;
        uint128 ratePerSecond; // akış hızı
        uint64 start;
        uint64 end;
        uint128 claimed;
        uint256 deposit; // toplam kilitlenen
        bool active;
    }

    IERC20 public immutable token;
    uint256 public nextId;
    mapping(uint256 => Stream) public streams;

    event StreamCreated(uint256 indexed id, address indexed sender, address indexed recipient, uint128 rate, uint64 start, uint64 end, uint256 deposit);
    event StreamCancelled(uint256 indexed id, uint256 senderRefund, uint256 recipientPayout);
    event Claimed(uint256 indexed id, address indexed recipient, uint256 amount);
    event RateUpdated(uint256 indexed id, uint128 newRate, uint64 newEnd);

    constructor(IERC20 _token) {
        token = _token;
    }

    function createStream(
        address recipient,
        uint128 ratePerSecond,
        uint64 start,
        uint64 end
    ) external returns (uint256 id) {
        require(recipient != address(0), "bad recipient");
        require(end > start, "time");
        require(ratePerSecond > 0, "rate=0");

        uint256 deposit = uint256(ratePerSecond) * (end - start);
        require(token.transferFrom(msg.sender, address(this), deposit), "transferFrom failed");

        id = ++nextId;
        streams[id] = Stream({
            sender: msg.sender,
            recipient: recipient,
            ratePerSecond: ratePerSecond,
            start: start,
            end: end,
            claimed: 0,
            deposit: deposit,
            active: true
        });

        emit StreamCreated(id, msg.sender, recipient, ratePerSecond, start, end, deposit);
    }

    function claimable(uint256 id) public view returns (uint256) {
        Stream memory s = streams[id];
        if (!s.active) {
            // pasifse, artık claimable sadece deposit-claimed olabilir (iptal sonrası)
            return s.deposit > s.claimed ? s.deposit - s.claimed : 0;
        }
        uint256 t = block.timestamp;
        if (t <= s.start) return 0;
        uint256 elapsed = t >= s.end ? s.end - s.start : t - s.start;
        uint256 earned = uint256(s.ratePerSecond) * elapsed;
        if (earned <= s.claimed) return 0;
        return earned - s.claimed;
    }

    function claim(uint256 id) public {
        Stream storage s = streams[id];
        require(msg.sender == s.recipient, "not recipient");
        uint256 amt = claimable(id);
        require(amt > 0, "nothing");
        s.claimed += uint128(amt);
        require(token.transfer(s.recipient, amt), "transfer failed");
        emit Claimed(id, s.recipient, amt);
    }

    function cancel(uint256 id) external {
        Stream storage s = streams[id];
        require(s.active, "inactive");
        require(msg.sender == s.sender, "not sender");

        uint256 amtToRecipient = claimable(id);
        // toplam rezerve: s.deposit
        uint256 totalPaid = s.claimed + amtToRecipient;
        uint256 refund = s.deposit > totalPaid ? s.deposit - totalPaid : 0;

        s.active = false;
        s.deposit = totalPaid; // depoyu “ödenen”e sabitle

        if (amtToRecipient > 0) {
            require(token.transfer(s.recipient, amtToRecipient), "pay failed");
        }
        if (refund > 0) {
            require(token.transfer(s.sender, refund), "refund failed");
        }
        emit StreamCancelled(id, refund, amtToRecipient);
    }

    function updateRate(uint256 id, uint128 newRate, uint64 newEnd) external {
        Stream storage s = streams[id];
        require(msg.sender == s.sender, "not sender");
        require(s.active, "inactive");
        require(newRate > 0 && newEnd > block.timestamp, "bad params");

        // önceye kadar hak edilen tutarı alıcı çekebilsin:
        uint256 amtToRecipient = claimable(id);
        if (amtToRecipient > 0) {
            s.claimed += uint128(amtToRecipient);
            require(token.transfer(s.recipient, amtToRecipient), "transfer failed");
        }

        // kalan rezerveyi güncellemek için önce mevcut kalan rezervi hesapla
        uint256 paid = s.claimed;
        require(s.deposit >= paid, "bad deposit");
        uint256 leftover = s.deposit - paid;

        // yeni planın gerektirdiği toplam = paid + (newRate * (newEnd - now))
        uint256 newRequired = paid + uint256(newRate) * (newEnd - uint64(block.timestamp));
        if (newRequired > s.deposit) {
            // ekstra fon iste
            uint256 need = newRequired - s.deposit;
            require(token.transferFrom(s.sender, address(this), need), "topup failed");
            s.deposit = newRequired;
        } else if (newRequired < s.deposit) {
            // fazla fon iade et
            uint256 excess = s.deposit - newRequired;
            require(token.transfer(s.sender, excess), "refund failed");
            s.deposit = newRequired;
        }

        s.ratePerSecond = newRate;
        s.start = uint64(block.timestamp);
        s.end = newEnd;

        emit RateUpdated(id, newRate, newEnd);
    }
}
