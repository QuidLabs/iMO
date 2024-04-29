
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity =0.8.8; 
// pragma experimental SMTChecker;
import "hardhat/console.sol"; // TODO comment out
import "./Dependencies/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MO is ERC20 { 
    AggregatorV3Interface public chainlink;
    IERC20 public sdai; address public lot; // multi-purpose (lock/lotto/OpEx)
    address constant public mevETH = 0x24Ae2dA0f361AA4BE46b48EB19C91e02c5e4f27E; 
    address constant public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant public SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address constant public QUID = 0x42cc020Ef5e9681364ABB5aba26F39626F1874A4;
    mapping(address => Pod) public _maturing; // QD from last 2 !MO...
    uint constant public ONE = 1e18; uint constant public DIGITS = 18;
    uint constant public MAX_PER_DAY = 7_777_777 * ONE; // supply cap
    uint constant public TARGET = 35700 * STACK; // !MO mint target
    uint constant public START_PRICE = 53 * CENT; // .54 actually
    uint constant public LENT = 46 days; // ends on the 47th day
    uint constant public STACK = C_NOTE * 100; // 10_000 in QD.
    uint constant public C_NOTE = 100 * ONE; 
    uint constant public RACK = STACK / 10;
    uint constant public CENT = ONE / 100;
    // investment banks underwriting IPO 
    // take 2-7%...compare this to 0.76%
    uint constant public MO_FEE = 54 * CENT; 
    uint constant public MO_CUT = 22 * CENT; 
    uint constant public MIN_CR = 108080808080808080; 
    uint constant public MIN_APR =  8080808080808080;               
    uint[27] public feeTargets; struct Medianiser { 
        uint apr; // most recent weighted median fee 
        uint[27] weights; // sum weights for each fee
        uint total; // _POINTS > sum of ALL weights... 
        uint sum_w_k; // sum(weights[0..k]) sum of sums
        uint k; // approximate index of median (+/- 1)
    } Medianiser public longMedian; // between 8-21%
    Medianiser public shortMedian; // 2 distinct fees
    Offering[16] public _MO; // one !MO per 6 months
    struct Offering { // 8 years x 544,444,444 sDAI
        uint start; // date 
        uint locked; // sDAI
        uint minted; // QD
        uint burned; // ^
        address[] own;
    }  uint public YEAR; // actually half a year, every 6 months
    uint internal _PRICE; // TODO comment out when finish testing
    uint internal _POINTS; // used in call() weights (medianiser)
    struct Pod { // used in Pools (incl. individual Plunges')
        uint credit; // in wind...this is hamsin (heat wave)
        uint debit; // in wind this is mevETH shares (chilly)
    }  // credit used for fee voting; debit for fee charging
    struct Owe { uint points; // time-weighted _balances of QD 
        Pod long; // debit = last timestamp of long APR payment;
        Pod short; // debit = last timestamp of short APR payment
        bool deux; // pay...✌🏻xAPR for peace of mind, and flip debt
        bool grace; // ditto ^^^^^ pro-rated _call but no ^^^^ ^^^^ 
    } // deux almighty and grace...married options are hard work...  
    struct Pool { Pod long; Pod short; } // work
    /*  The first part is called "The Pledge"... 
        An imagineer shows you something ordinary: 
        to see if it's...indeed un-altered, normal 
    */ Pod internal carry; // cost of carry as we:
    struct Plunge { // pledge to plunge into work...
        uint last; // timestamp of last state update
        Pool work; // debt and collat (long OR short)
        Owe dues; // all kinds of utility variables
        uint eth; // Marvel's (pet) Rock of Eternity
    }   mapping (address => Plunge) Plunges;
    Pod internal wind; Pool internal work; // internally 1 sDAI = 1 QD
    constructor(address _lot, address _price) ERC20("QU!Dao", "QD") { 
        _MO[0].start = 1719444444; lot = _lot; 
        feeTargets = [MIN_APR, 85000000000000000,  90000000000000000,
           95000000000000000, 100000000000000000, 105000000000000000,
          110000000000000000, 115000000000000000, 120000000000000000,
          125000000000000000, 130000000000000000, 135000000000000000,
          140000000000000000, 145000000000000000, 150000000000000000,
          155000000000000000, 160000000000000000, 165000000000000000,
          170000000000000000, 175000000000000000, 180000000000000000,
          185000000000000000, 190000000000000000, 195000000000000000,
          200000000000000000, 205000000000000000, 210000000000000000];
        chainlink = AggregatorV3Interface(_price);
        uint[27] memory blank; sdai = IERC20(SDAI);
        longMedian = Medianiser(MIN_APR, blank, 0, 0, 0);
        shortMedian = Medianiser(MIN_APR, blank, 0, 0, 0); 
    }

    event Minted (address indexed reciever, uint cost_in_usd, uint amt); // by !MO
    // Events are emitted, so only when we emit profits for someone do we call...
    event Long (address indexed owner, uint amt); 
    event Short (address indexed owner, uint amt);
    event Voted (address indexed voter, uint vote); // only emit when increasing

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                       HELPER FUNCTIONS                     */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/
    
    // TODO comment out after finish testing
    function set_price(uint price) external { // set ETH price in USD
        _PRICE = price;
    }
    
    function _min(uint _a, uint _b) internal pure returns (uint) {
        return (_a < _b) ? _a : _b;
    }

    /**
     * Override the ERC20 functions to account 
     * for QD balances that are still maturing  
     */

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        Plunge memory plunge = _fetch(_msgSender(), 
                 _get_price(), false, _msgSender()
        );  _send(_msgSender(), recipient, amount, true); 
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        Plunge memory plunge = _fetch(_msgSender(),  
                 _get_price(), false, _msgSender()
        );  _send(from, to, value, true); 
        return true;
    }

    // in _call, the ground you stand on balances you...what balances the ground?
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) + _maturing[account].debit +  _maturing[account].credit;
        // mature QD ^^^^^^^^^ in the process of maturing as ^^^^^ or starting to mature ^^^^^^
    }

    function liquidated(uint when) public view returns (address[] memory) {
        return _MO[when].own;
    }

    function _ratio(uint _multiplier, uint _numerator, uint _denominator) internal pure returns (uint ratio) {
        if (_denominator > 0) {
            ratio = _multiplier * _numerator / _denominator;
        } else { // if  Plunge has a debt of 0: "infinite" CR
            ratio = type(uint256).max - 1; 
        }
    }

    // calculates CR (value of collat / value of debt)...if you look a little pale, might credshort a cold
    function _blush(uint _price, uint _collat, uint _debt, bool _short) internal pure returns (uint) {   
        if (_short) {
            uint debt_in_QD = _ratio(_price, _debt, ONE); 
            return _ratio(ONE, _collat, debt_in_QD); // collat is in QD
            // we multiply collat first to preserve precision 
        } else {
            return _ratio(_price, _collat, _debt); // debt is in QD
        } 
    }
    
    // _send _it !
    function _it(address from, address to, uint256 value) internal returns (uint) {
        uint delta = _min(_maturing[from].credit, value);
        _maturing[from].credit -= delta; value -= delta;
        if (to != address(this)) { _maturing[to].credit += delta; }
        if (value > 0) {
            delta = _min(_maturing[from].debit, value);
            _maturing[from].debit -= delta; value -= delta;
            if (to != address(this)) { _maturing[to].debit += delta; }
        }   return value; 
    }

    // bool matured indicates priority to use in control flow (to charge) 
    function _send(address from, address to, uint256 value, bool matured) 
        internal { require(from != address(0) && to == address(0), 
                           "MO::send: passed in zero address");
        uint delta;
        if (!matured) {
            delta = _it(from, to, value);
            if (delta > 0) { _transfer(from, to, delta); }
        } else { // fire doesn't erase blood, QD is never burned
            delta = _min(super.balanceOf(from), value);
            _transfer(from, to, delta); value -= delta;
            if (value > 0) {
                require(_it(from, to, value) == 0, 
                "MO::send: insufficient funds");
            } // address(this) will never _send QD
        }   
    }

    /** 
     * Returns the latest price obtained from the Chainlink ETH:USD aggregator 
     * reference contract...https://docs.chain.link/docs/get-the-latest-price
     */

    function _get_price() internal view returns (uint price) {
        if (_PRICE != 0) { return _PRICE; } // TODO comment when done testing
        (, int priceAnswer,, uint timeStamp,) = chainlink.latestRoundData();
        require(timeStamp > 0 && timeStamp <= block.timestamp,
                "MO::price: timestamp is 0, or in future");
        require(priceAnswer >= 0, "MO::price: negative");
        uint8 answerDigits = chainlink.decimals();
        price = uint256(priceAnswer);
        // currently the Aggregator returns an 8-digit precision, but we handle the case of future changes
        if (answerDigits > DIGITS) { price /= 10 ** (answerDigits - DIGITS); }
        else if (answerDigits < DIGITS) { price *= 10 ** (DIGITS - answerDigits); } 
    }

    /** To be responsive to DSR changes we have dynamic APR 
     *  using a points-weighted median algorithm for voting:
     *  not too dissimilar github.com/euler-xyz/median-oracle
     *  Find value of k in range(0, len(Weights)) such that 
     *  sum(Weights[0:k]) = sum(Weights[k:len(Weights)+1])
     *  = sum(Weights) / 2
     *  If there is no such value of k, there must be a value of k 
     *  in the same range range(0, len(Weights)) such that 
     *  sum(Weights[0:k]) > sum(Weights) / 2
     *  TODO update total points only here ? 
     */
    function _medianise(uint new_stake, uint new_vote, 
        uint old_stake, uint old_vote, bool short) internal { 
        uint delta = MIN_APR / 16; // update annual average in Offering TODO
        Medianiser memory data = short ? shortMedian : longMedian;
        // when k = 0 it has to be 
        if (old_vote != 0 && old_stake != 0) { // clear old values
            uint old_index = (old_vote - MIN_APR) / delta;
            data.weights[old_index] -= old_stake;
            data.total -= old_stake;
            if (old_vote <= data.apr) {   
                data.sum_w_k -= old_stake;
            }
        } uint index = (new_vote 
            - MIN_APR) / delta;
        if (new_stake != 0) {
            data.total += new_stake;
            if (new_vote <= data.apr) {
                data.sum_w_k += new_stake;
            }		  
            data.weights[index] += new_stake;
        } uint mid_stake = data.total / 2;
        if (data.total != 0 && mid_stake != 0) {
            if (data.apr > new_vote) {
                while (data.k >= 1 && (
                     (data.sum_w_k - data.weights[data.k]) >= mid_stake
                )) { data.sum_w_k -= data.weights[data.k]; data.k -= 1; }
            } else {
                while (data.sum_w_k < mid_stake) { data.k += 1;
                       data.sum_w_k += data.weights[data.k];
                }
            } data.apr = feeTargets[data.k];
            if (data.sum_w_k == mid_stake) { 
                uint intermedian = data.apr + ((data.k + 1) * delta) + MIN_APR;
                data.apr = intermedian / 2;  
            }
        }  else { data.sum_w_k = 0; } 
        if (!short) { longMedian = data; } 
        else { shortMedian = data; } // fin
    }

    // ------------ OPTIONAL -----------------
    // voting can allow LTV to act as moneyness,
    // but while DSR is high this is unnecessary  

    // DRIP (divident reinvestmnent plan) 
    // with respect to _get_owe(), called 
    // internally in 3 places functions...
    // http://instagram.com/p/C5XMnorLj-c 
    function _get_owe(uint param) internal {   
        
        // using APR / into MIN = scale
        // if you over-collat by 8% x scale
        // then you get a discount from APR
        // that is exactly proportional...
        // means we do have to add it in _call

        // transfer to Lot.

        uint excess = YEAR * TARGET; // excess wind.credit
        if (wind.credit > excess) {

        } else {

        }
    }   // "so listen this is how I shed my tears (crying down coins)
    // ...a [_get_owe work] is the law that we live by" ~ Legal Money
    

    function _fetch(address addr, uint price, bool must_exist, address caller) 
        internal returns (Plunge memory plunge) { plunge = Plunges[addr]; 
        require(!must_exist || plunge.last != 0, "MO: plunge must exist");
        // if it's not the last, then others will continue to exist...
        bool clocked = false; uint old_points; uint grace; uint time;
        // over the course of a MO every participant must do at least
        // one _fetch so balances are ready for call(once a year)
        if ((YEAR % 2 == 1) && (_maturing[addr].credit > 0)) { // TODO only do this if pledge.last > 0 
            
            // TODO can't be a require must be an if 
            // FIXME call from temporary balances if current MO failed ??
            require(block.timestamp >= _MO[0].start + LENT &&
                _MO[0].minted >= TARGET, "MO::get: early"); 
            if (_maturing[addr].debit == 0) {
                _maturing[addr].debit = _maturing[addr].credit;
                _maturing[addr].credit = 0;
            }
            // TODO track total so that in mint or withdraw we know
        } else if (_maturing[addr].debit > 0) { // !MO # 2 4 6 8...
            // debit for 2 is credit from 0...then for 2 from 4...
            _mint(addr, _maturing[addr].debit); // minting only here...
            _maturing[addr].debit = 0; // no minting in mint() function
        } // else if () FIXME
        old_points = plunge.dues.points; 
        _POINTS -= old_points; uint _eth = plunge.eth; 
        // wait oh wait oh wait oh wait oh wait oh wait oh wait...
        uint fee = caller == addr ? 0 : MIN_APR / 2000;  // 0.0041 %
        if (plunge.work.short.debit > 0) { 
            Pod memory _work = plunge.work.short; 
            fee *= _work.debit / ONE;
            time = plunge.dues.short.debit > block.timestamp ? 
                0 : block.timestamp - plunge.dues.short.debit; 
            if (plunge.dues.deux) { grace = 1; // used in _call
                if (plunge.dues.grace) { // 144x per day is
                    // (24 hours * 60 minutes) / 10 minutes
                    grace = (MIN_APR / 1000) * _work.debit / ONE; // 1.15% per day
                    grace += fee; // 0,5% per day for caller
                } 
            }   (_work, _eth, clocked) = _charge(addr, 
                 _eth, _work, price, time, grace, true); 
            if (clocked) { 
                if (grace == 1) { plunge.dues.short.debit = 0;
                    plunge.work.short.credit = 0;
                    plunge.work.short.debit = 0;
                    plunge.work.long.credit = _work.credit;
                    plunge.work.long.debit = _work.debit;
                    plunge.dues.long.debit = block.timestamp + 1 days; 
                }   else if (grace > 1) { // slow drip option
                    plunge.dues.short.debit = block.timestamp; 
                }   else { plunge.dues.short.debit = 0; }
            } else { plunge.dues.short.debit = block.timestamp; }   
            plunge.work.short = _work; 
        }   
        else if (plunge.work.long.debit > 0) {
            Pod memory _work = plunge.work.long;
            fee *= _work.debit / ONE; // liquidator's fee for gas
            time = plunge.dues.long.debit > block.timestamp ? 
                0 : block.timestamp - plunge.dues.long.debit; 
            if (plunge.dues.deux) { grace = 1; // used in _call
                if (plunge.dues.grace) { // 144x per day is
                    // (24 hours * 60 minutes) / 10 minutes
                    grace = (MIN_APR / 1000) * _work.debit / ONE; // 1.15% per day
                    grace += fee; // 0,5% per day for caller
                } 
            }   (_work, _eth, clocked) = _charge(addr, 
                 _eth, _work, price, time, grace, false); 
            if (clocked) { // festina...lent...eh? make haste
                if (grace == 1) { plunge.dues.long.debit = 0;
                    plunge.work.long.credit = 0;
                    plunge.work.long.debit = 0;
                    plunge.work.short.credit = _work.credit;
                    plunge.work.short.debit = _work.debit;
                    plunge.dues.short.debit = block.timestamp + 1 days;
                    // a grace period is provided for calling put(),
                    // otherwise can get stuck in an infinite loop
                    // of throwing back & forth between directions
                }   else if (grace > 1) { // slow drip option
                    plunge.dues.long.debit = block.timestamp; 
                }   else { plunge.dues.long.debit = 0; }
            } else { plunge.dues.long.debit = block.timestamp; }  
            plunge.work.long = _work;
        } 
        if (fee > 0) { _maturing[caller].credit += fee; }
        if (balanceOf(addr) > 0) { // TODO default vote not counted
            // TODO simplify based on !MO
            plunge.dues.points += ( // 
                ((block.timestamp - plunge.last) / 1 hours) 
                * balanceOf(addr) / ONE
            ); 
            // carry.credit; // is subtracted from 
            // rebalance fee targets (governance)
            if (plunge.dues.long.credit != 0) { 
                _medianise(plunge.dues.points, 
                    plunge.dues.long.credit, old_points, 
                    plunge.dues.long.credit, false
                );
            } if (plunge.dues.short.credit != 0) {
                _medianise(plunge.dues.points, 
                    plunge.dues.short.credit, old_points, 
                    plunge.dues.short.credit, true
                );
            }   _POINTS += plunge.dues.points;
        }   
        plunge.last = block.timestamp; plunge.eth = _eth;
    }

    function _charge(address addr, uint _eth, Pod memory _work, 
        uint price, uint delta, uint grace, bool short) internal 
        returns (Pod memory, uint, bool clocked) {
        // "though eight is not enough...no,
        // it's like [grace lest you] bust: 
        // now your whole [plunge] is dust" 
        if (delta >= 10 minutes) { // 52704 x 10 mins per year
            uint apr = short ? shortMedian.apr : longMedian.apr; 
            delta /= 10 minutes; uint owe = (grace > 0) ? 2 : 1; 
            owe *= (apr * _work.debit * delta) / (52704 * ONE);
            // need to reuse the delta variable (or stack too deep)
            delta = _blush(price, _work.credit, _work.debit, short);
            if (delta < ONE) { // liquidatable potentially
                (_work, _eth, clocked) = _call(addr, _work, _eth, 
                                               grace, short, price);
            }  else { // healthy CR, proceed to charge APR
                // if addr is shorting: indicates a desire
                // to give priority towards getting rid of
                // ETH first, before spending available QD
                grace = _ratio(price, _eth, ONE); // reuse var lest stack too deep
                uint most = short ? _min(grace, owe) : _min(balanceOf(addr), owe);
                if (owe > 0 && most > 0) { 
                    if (short) { owe -= most;
                        most = _ratio(ONE, most, price);
                        _eth -= most; carry.debit -= most;
                        wind.debit += most; 
                        bytes memory payload = abi.encodeWithSignature(
                        "deposit(uint256,address)", most, address(this));
                        (bool success,) = mevETH.call{value: most}(payload); 
                    } else { _send(addr, address(this), most, false);
                        wind.credit -= most; // equivalent of burning QD
                        // carry.credit += most would be a double spend
                        owe -= most;
                    }
                } if (owe > 0) { 
                    // do it backwards from original calculation
                    most = short ? _min(balanceOf(addr), owe) : _min(grace, owe);
                    // if the last if block was a long, grace was untouched
                    if (short && most > 0) { 
                        _send(addr, address(this), most, false);
                        wind.credit -= most; owe -= most;
                    }   
                    else if (!short && most > 0) { owe -= most;
                        most = _ratio(ONE, most, price);
                        _eth -= most; carry.debit -= most;
                        wind.debit += most; 
                        bytes memory payload = abi.encodeWithSignature(
                        "deposit(uint256,address)", most, address(this));
                        (bool success,) = mevETH.call{value: most}(payload); 
                    }   if (owe > 0) { // plunge cannot pay APR (delinquent)
                            (_work, _eth, clocked) = _call(addr, _work, _eth, 
                                                        0, short, price);
                            // zero passed in for grace...^
                            // because...even if the plunge
                            // elected to be treated gracefully
                            // there is an associated cost for it
                        } 
                }   
            } 
        }   return (_work, _eth, clocked);
    }  
    
    // "So close no matter how far, rage be in it like you 
    // couldn’t believe...or work like one could scarcely 
    // imagine...if one isn’t satisfied, indulge the latter
    // ‘neath the halo of a street-lamp...I fold my collar
    // to the cold and damp...know when to hold 'em...know 
    // when to..." 
    function _call(address owner, Pod memory _work, uint _eth, 
                   uint grace, bool short, uint price) internal 
                   returns (Pod memory, uint, bool folded) { 
        uint in_QD = _ratio(price, _work.credit, ONE); uint in_eth;
        require(in_QD > 0, "MO: nothing to _call in"); folded = true;
        if (short) { // plunge into pool (caught the wind on low) 
            if (_work.debit > in_QD) { // value of credit fell
                work.short.debit -= _work.debit; // return what
                carry.credit += _work.debit; // has been debited
                _work.debit -= in_QD; // remainder is profit...
                wind.credit += _work.debit; // associated debt 
                _maturing[owner].credit += _work.debit;
                // _maturing credit takes 1 year to get
                // into _balances (redeemable for sDAI)
                work.short.credit -= _work.credit;
                _work.debit = 0; _work.credit = 0;  
            } // in_QD is worth more than _work.debit, price went up... 
            else { // "lightnin' strikes and the court lights get dim"
                if (grace == 0) { // try to prevent folded from happening
                    uint delta = (in_QD * MIN_CR) / ONE - _work.debit;
                    uint salve = balanceOf(owner) + _ratio(price, _eth, ONE); 
                    if (delta > salve) { delta = in_QD - _work.debit; } 
                    // "It's like inch by inch and step by step...i'm closin'
                    // in on your position and [reconstruction] is my mission"
                    if (salve >= delta) { folded = false; // salvageable...
                        // decrement QD first because ETH is rising
                        in_eth = _ratio(ONE, delta, price);
                        uint most = _min(balanceOf(owner), delta);
                        if (most > 0) { delta -= most;
                            _send(owner, address(this), most, false);
                            // TODO double check re carry.credit or wind.credit
                        } if (delta > 0) { most = _ratio(ONE, delta, price);
                            _eth -= most; wind.debit += most; carry.debit -= most; 
                            bytes memory payload = abi.encodeWithSignature(
                            "deposit(uint256,address)", most, address(this));
                            (bool success,) = mevETH.call{value: most}(payload); 
                            require(success, "MO::mevETH");
                        } _work.credit -= in_eth;
                        work.short.credit -= in_eth;
                    } else { emit Short(owner, _work.debit);
                        carry.credit += _work.debit; 
                        if (_work.debit > 5 * STACK) { 
                            _MO[YEAR].own.push(owner); // for Lot.sol
                        }   work.short.debit -= _work.debit;
                            work.short.credit -= _work.credit;
                            _work.credit = 0; _work.debit = 0;
                    }
                }   else if (grace == 1) { // no return to carry
                        work.short.credit -= _work.credit;
                        work.long.credit += _work.credit;
                        work.short.debit -= _work.debit;
                        work.long.debit += _work.debit;
                } else { // partial return to carry
                    _work.debit -= grace; in_eth = _ratio(ONE, grace, price);
                    _work.credit -= in_eth; work.short.credit -= in_eth; 
                    work.short.debit -= grace; carry.credit += grace;
                } 
            }   
        } else { // plunge into leveraged long pool  
            if (in_QD > _work.debit) { // caught the wind (high)
                in_QD -= _work.debit; // profit is remainder
                _maturing[owner].credit += in_QD;
                carry.credit += _work.debit; 
                wind.credit += in_QD; 
                work.long.debit -= _work.debit;
                work.long.credit -= _work.credit;
                _work.debit = 0; _work.credit = 0;                 
            }   else {
                if (grace == 0) {
                    uint delta = (_work.debit * MIN_CR) / ONE - in_QD;
                    uint salve = balanceOf(owner) + _ratio(price, _eth, ONE); 
                    if (delta > salve) { delta = _work.debit - in_QD; } 
                    if (salve >= delta) { folded = false; // salvageable
                        // decrement ETH first because it's falling
                        in_eth = _ratio(ONE, delta, price); 
                        uint most = _min(_eth, in_eth);
                        if (most > 0) { carry.debit -= most; // remove ETH from carry
                            _eth -= most; wind.debit += most; // sell ETH, so 
                            // original ETH is not callable or puttable by the Plunge
                            in_QD = _ratio(price, most, ONE);
                            work.long.debit -= in_QD;
                            _work.debit -= in_QD; delta -= in_QD;
                            bytes memory payload = abi.encodeWithSignature(
                            "deposit(uint256,address)", most, address(this));
                            (bool success,) = mevETH.call{value: most}(payload); 
                            require(success, "MO::mevETH");
                        } if (delta > 0) { _send(owner, address(this), delta, false); 
                            in_eth = _ratio(ONE, delta, price); _work.credit += in_eth;
                            work.long.credit += in_eth;
                        }
                    } // "Don't get no better than this, you catch my drift?"
                    else { emit Long(owner, _work.debit);
                        carry.credit += _work.debit; 
                        if (_work.debit > 5 * STACK) { 
                            _MO[YEAR].own.push(owner); // for Lot.sol
                        }   work.long.debit -= _work.debit;
                            work.long.credit -= _work.credit;
                            _work.credit = 0; _work.debit = 0;
                    }
                } else if (grace == 1) { // no return to carry
                    work.long.credit -= _work.credit;
                    work.short.credit += _work.credit;
                    work.long.debit -= _work.debit;
                    work.short.debit += _work.debit;
                } else { // partial return to carry
                    _work.debit -= grace; in_eth = _ratio(ONE, grace, price);
                    _work.credit -= in_eth; work.long.credit -= in_eth; 
                    work.long.debit -= grace; carry.credit += grace;
                }  
            } 
        }   return (_work, _eth, folded);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                     EXTERNAL FUNCTIONS                     */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/
    // mint...flip...vote...put...borrow...fold...call...
    // "lookin' too hot...simmer down, or soon you'll get" 
    function clocked(address[] memory plunges) external { 
        uint price = _get_price(); 
        for (uint i = 0; i < plunges.length; i++ ) {
            _fetch(plunges[i], price, true, _msgSender());
        } 
    } 
    
    function flip(bool grace) external { uint price = _get_price();
        Plunge memory plunge = _fetch(_msgSender(), price, true, _msgSender());
        if (grace) { plunge.dues.deux = true; plunge.dues.grace = true; } else {
            plunge.dues.deux = !plunge.dues.deux; plunge.dues.grace = false;
        }   Plunges[_msgSender()] = plunge; // write to storage, we're done
    }

    function fold(bool short) external { 
        Pod memory _work; uint price = _get_price();
        Plunge memory plunge = _fetch(_msgSender(), price,
                                      true, _msgSender());
        if (short) { 
            (_work,,) = _call(_msgSender(), plunge.work.short, 
                              plunge.eth, 0, true, price); 
            plunge.dues.short.debit = 0;
            plunge.work.short = _work; 
        } else { 
            (_work,,) = _call(_msgSender(), plunge.work.long, 
                              plunge.eth, 0, false, price); 
            plunge.dues.long.debit = 0;
            plunge.work.long = _work; 
        }   Plunges[_msgSender()] = plunge; 
    }

    // truth is the highest vibration (not love).  
    function vote(uint apr, bool short) external {
        uint delta = MIN_APR / 16; // half a percent 
        require(apr >= MIN_APR && apr <= 
            (MIN_APR * 3 - delta * 6) &&
            apr % delta == 0, "MO::vote");
        uint old_vote; // a vote of confidence gives...credit (credit)
        uint price = _get_price(); Plunge memory plunge = _fetch(
            _msgSender(), price, true, _msgSender()
        );
        if (short) {
            old_vote = plunge.dues.short.credit;
            plunge.dues.short.credit = apr;
        } else {
            old_vote = plunge.dues.long.credit;
            plunge.dues.long.credit = apr;
        }
        _medianise(plunge.dues.points, apr, 
        plunge.dues.points, old_vote, short);
        Plunges[_msgSender()] = plunge;
    }

    function put(address beneficiary, uint amount, bool _eth, bool long)
        external payable { uint price = _get_price(); uint most;
        Plunge memory plunge = _fetch(beneficiary, price,
                                      false, _msgSender());
        if (!_eth) { _send(_msgSender(), address(this), amount, false);
            uint eth = _ratio(ONE, amount, price);
            if (long) { work.long.credit += eth;
                plunge.work.long.credit += eth;
                // TODO decrement carry.credit and wind.credit?
            } else { 
                most = _min(eth, plunge.work.short.credit);
                plunge.work.short.credit -= eth;
                work.short.credit -= eth;
            }  // do nothing with remainder (amount - most)
        }   else { 
            if (!long && plunge.work.short.credit == 0) {
                carry.debit += amount;
                plunge.eth += amount; // deposit (no mevETH)
                // must be withdrawable instantly (own funds)
            }   else { // sell ETH (throw caution to the wind)
                    if (plunge.work.short.credit > 0) { 
                        most = _min(amount, plunge.work.short.credit);
                        require(msg.value + plunge.eth >= most, "MO::put: short");
                        plunge.work.short.credit -= most; work.short.credit -= most;
                        uint delta;
                        if (most > msg.value) { 
                            delta = most - msg.value;
                            carry.debit -= delta;
                            plunge.eth -= delta; 
                        } 
                        else { delta = msg.value - most;
                            plunge.eth += delta;
                            carry.debit += delta; 
                        }
                    } else if (plunge.work.long.credit > 0) { 
                        most = _min(msg.value + plunge.eth, amount);
                        if (most > msg.value) { 
                            uint delta = most - msg.value;
                            carry.debit -= delta;
                            plunge.eth -= delta; 
                        }   plunge.work.long.credit += most;
                    }   bool success; bytes memory payload = abi.encodeWithSignature(
                            "deposit(uint256,address)", most, address(this)
                        );  (success,) = mevETH.call{value: most}(payload); 
                            require(success, "MO::put: mevETH");  
                }
        }   Plunges[beneficiary] = plunge;
    }

    // "collect calls to the tip sayin' how ya changed" 
    function call(uint amt, bool qd, bool eth) external { 
        uint most; uint cr; uint price = _get_price();
        Plunge memory plunge = _fetch(
            _msgSender(), price, true, _msgSender());
        if (!qd) { // call only from carry...use escrow() or fold() for work 
            // the work balance is a synthetic (virtual) representation of ETH
            // plunges only care about P&L, which can only be called in QD 
            most = _min(plunge.eth, amt);
            plunge.eth -= most;
            carry.debit -= most;
            // require(address(this).balance > most, "MO::call: deficit ETH");
            payable(_msgSender()).transfer(most); // TODO use WETH to put % in Lock?
        } 
        else if (qd) {         
            // but we must also be able to evict (involuntary fold from profitables)
            // consider that extra minting happens here 
            // in order to satisfy call (in that sense perfection rights are priotised)
            // this automatically ensures that YEAR > 1
            
            

            require(super.balanceOf(_msgSender()) >= amt, 
                    "MO::call: insufficient QD balance");
            require(amt >= RACK, "MO::call: must be over 1000");
                   
            // POINTS (per plunge are products) sum in total
            // _get_owe(_POINTS);
            // so that plunges that have been around since
            // the beginning don't take the same proportion
            // as recently joined plegdes, which may other-
            // wise have the same stake-based equity in wind
            // so it's a product of the age and stake instead

            // carry.CREDIT OVER TIME (TOTAL POINTS)
            // WILL GET ITS SHARE OF THE WP AT THE END  ??
            // 1/16 * _get_owe_scale 
            // (carry - wind).credit
              
            uint assets = carry.credit + work.short.debit + work.long.debit + 
            _ratio(price, wind.debit, ONE) + _ratio(price, carry.debit, ONE); 

            // TODO collapse work positions back into carry 
            // can only call from what is inside carry

            // 1/16th or 1/8th 
            uint liabilities = wind.credit + // QDebt from !MO 
            _ratio(price, work.long.credit, ONE) + // synthetic ETH collat
            _ratio(price, work.short.credit, ONE);  // synthetic ETH debt
         
            if (liabilities > assets) {

            } else { 
                
                // carry.credit -= least; _burn(_msgSender(), amt); 
                // sdai.transferFrom(address(this), _msgSender(), amt);
            }      
        }
    } 

    // TODO bool qd, this will attempt to draw _max from _balances before sDAI 
    function mint(uint amount, address beneficiary) external returns (uint cost) {
        require(beneficiary != address(0), "MO::mint: zero address");
        require(block.timestamp >= _MO[YEAR].start, "MO::mint: before start date"); 
        // TODO allow roll over QD value in sDAI from last !MO into new !MO...

        // evict the wei used to store Offering data after 
        // the end of the offering? TODO

        if (block.timestamp >= _MO[YEAR].start + LENT + 144 days) { // 6 months
            if (_MO[YEAR].minted >= TARGET) { // _MO[YEAR].locked * MO_FEE / ONE
                sdai.transferFrom(address(this), lot, 1477741 * ONE); // ^  
                _MO[YEAR].locked = 272222222 * ONE; // minus 0.54% of sDAI
            }   YEAR += 1; // "same level, the same
            //  rebel that never settled" in _get_owe()
            require(YEAR <= 16, "MO::mint: already had our final !MO");
            _MO[YEAR].start = block.timestamp + LENT; // in the next !MO
        } else if (YEAR < 16) { // forte vento, LENT gives time to _fetch
            require(amount >= RACK, "MO::mint: a rack minimum, no iraq"); 
            uint in_days = ((block.timestamp - _MO[YEAR].start) / 1 days) + 1; 
            require(in_days < 46, "MO::mint: current !MO is over"); 
            cost = (in_days * CENT + START_PRICE) * (amount / ONE);
            uint supply_cap = in_days * MAX_PER_DAY + totalSupply();
            if (Plunges[beneficiary].last == 0) { // init. plunge
                Plunges[beneficiary].last = block.timestamp;
                _approve(beneficiary, address(this),
                          type(uint256).max - 1);
            } _MO[YEAR].locked += cost; _MO[YEAR].minted += amount;
            wind.credit += amount; // the debts associated with QD
            // balances belong to everyone, not to any individual;
            // amount decremented by APR payments in QD (or call)
            uint cut = MO_CUT * amount / ONE; // .22% = 777742 QD
            _maturing[beneficiary].credit += amount - cut; // QD
            _mint(lot, cut); carry.credit += cost; 
            emit Minted(beneficiary, cost, amount); 
            require(supply_cap >= wind.credit,
            "MO::mint: supply cap exceeded"); 

            // TODO helper function
            // for how much credit to mint
            // based on target (what was minted before) and what is surplus from fold
            // different input to _get_owe(). fold only credits a carry to the plunge winsin
            
            // wind.credit 
            // TODO add amt to plunge.carry.credit ??
            
            sdai.transferFrom(_msgSender(), address(this), cost); // TODO approve in frontend
            
        }
    }

    function borrow(uint amount, bool short) external payable { // amount is in QD 
        require(block.timestamp >= _MO[0].start + LENT &&
                _MO[0].minted >= TARGET, "MO::escrow: early");    
        // if above fails must call call for sDAI refund ? 
        uint price = _get_price(); uint debit; uint credit; 
        Plunge memory plunge = _fetch(_msgSender(), price, 
                                      false, _msgSender()); 

        // TODO cannot borrow more while in grace
        if (short) { 
            require(plunge.work.long.debit == 0 
            && plunge.dues.long.debit == 0, // timestmap
            "MO::escrow: plunge is already long");
            plunge.dues.short.debit = block.timestamp;
        } else { require(plunge.work.short.debit == 0 
            && plunge.dues.short.debit == 0, // timestamp
            "MO::escrow: plunge is already short");
            plunge.dues.long.debit = block.timestamp;
        }
        uint _carry = balanceOf(_msgSender()) + _ratio(price,
        plunge.eth, ONE); uint old = carry.credit * 85 / 100;
        uint eth = _ratio(ONE, amount, price); // amount of ETH being credited:
        uint max = plunge.dues.deux ? 2 : 1; // used in require(max escrowable)
        
            // TODO
            // bytes memory payload = abi.encodeWithSignature(
            // "deposit(uint256,address)", most, address(this));
            // (bool success,) = mevETH.call{value: most}(payload); 
        
        if (!short) { max *= longMedian.apr; eth += msg.value; // wind
            // we are crediting the plunge's long with virtual credit 
            // in units of ETH (its sDAI value is owed back to carry) 
            plunge.work.long.credit += eth; work.long.credit += eth;
            // put() of QD to short work will reduce credit value
            // we debited (in sDAI) by drawing from carry, recording 
            // the total value debited (and value of the ETH credit)
            // will determine the P&L of the position in the future
            plunge.work.long.debit += amount; carry.credit -= amount;
            // increments a liability (work); decrements an asset^
            work.long.debit += amount; wind.debit += msg.value; 
            // essentially debit is the collat backing the credit
            debit = plunge.work.long.debit; credit = plunge.work.long.credit;
        } else { max *= shortMedian.apr; // see above for explanation
            plunge.work.short.credit += eth; work.short.credit += eth;
            // put() of QD to work.sort will reduce debit owed that
            // we debited (in sDAI) by drawing from carry (and recording)
            plunge.work.short.debit += amount; carry.credit -= amount;
            eth = _min(msg.value, plunge.work.short.credit);
            plunge.work.short.credit -= eth; // there's no way
            work.short.credit -= eth; // to burn actual ETH so
            wind.debit += eth; // ETH belongs to all plunges
            eth = msg.value - eth; plunge.eth += eth;
            carry.debit += eth; work.short.debit += amount; 
            debit = plunge.work.short.debit; credit = plunge.work.short.credit;
        }   require(old > work.short.credit + work.long.credit, "MO::escrow");
        require(_blush(price, credit, debit, short) >= MIN_CR && // too much...
        (carry.credit / 5 > debit) && _carry > (debit * max / ONE), 
            "MO::escrow: taking on more leverage than considered healthy"
        ); Plunges[_msgSender()] = plunge; // write to storage last 
    }
}
