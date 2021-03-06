# Ice Breaker AR Token/Token Sale 

Required: Node 8.x latest

Install truffle (v4) and ganache-cli
```
npm i -g truffle
npm i -g ganache-cli
```

Install packages
```
npm install
```

Init truffle config
```
cp truffle.js.example truffle.js
```

Run ganache-cli
```
ganache-cli -e 1000000
```

Run tests
```
truffle test
```

To deploy to Testnet/Mainnet, set the proper network settings in truffle.js, then for example for kovan (replace MY_VAULT_ADDRESS, MY_KYC_ADDRESS, TOKEN_BASE_RATE, REFERRER_BONUS_RATE with the actual values)
```
VAULT_ADDRESS=MY_VAULT_ADDRESS KYC_ADDRESS=MY_KYC_ADDRESS TOKEN_BASE_RATE=MY_TOKEN_BASE_RATE REFERRER_BONUS_RATE=MY_REFERRER_BONUS_RATE truffle migrate --network=kovan
```

## Check pending reservations

```
truffle exec truffle-scripts/check-pending-reservations.js 
```