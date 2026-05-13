// LayerZero V2 OFT on Starknet — Mock USDC, 6 decimals on both sides.
//
// Mirror of the canonical OFT mock at
//   @layerzerolabs/protocol-starknet-v2/layerzero/tests/mocks/oft_core/oft_core.cairo
// but with 6 local decimals (USDC-style) and a public `faucet()` so the
// browser demo can self-mint test tokens without owner ceremony.

#[starknet::contract]
pub mod MockUsdcOft {
    use layerzero::oapps::common::oapp_options_type_3::oapp_options_type_3::OAppOptionsType3Component;
    use layerzero::oapps::oapp::oapp_core::OAppCoreComponent;
    use layerzero::oapps::oft::oft_core::default_oapp_hooks::OFTCoreOAppHooksDefaultImpl;
    use layerzero::oapps::oft::oft_core::default_oft_hooks::OFTCoreOFTHooksDefaultImpl;
    use layerzero::oapps::oft::oft_core::oft_core::OFTCoreComponent;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use starknet::{ContractAddress, get_caller_address};

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: OAppCoreComponent, storage: oapp_core, event: OAppCoreEvent);
    component!(path: OFTCoreComponent, storage: oft_core, event: OFTCoreEvent);
    component!(
        path: OAppOptionsType3Component, storage: oapp_options_type_3, event: OAppOptionsType3Event,
    );

    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    impl ERC20ImmutableConfig of ERC20Component::ImmutableConfig {
        const DECIMALS: u8 = 6;
    }

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl OAppCoreImpl = OAppCoreComponent::OAppCoreImpl<ContractState>;
    impl OAppCoreInternalImpl = OAppCoreComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl IOAppReceiverImpl = OAppCoreComponent::OAppReceiverImpl<ContractState>;

    #[abi(embed_v0)]
    impl ILayerZeroReceiverImpl =
        OAppCoreComponent::LayerZeroReceiverImpl<ContractState>;

    #[abi(embed_v0)]
    impl OFTCoreImpl = OFTCoreComponent::OFTCoreImpl<ContractState>;
    impl OFTCoreInternalImpl = OFTCoreComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl OAppOptionsType3Impl =
        OAppOptionsType3Component::OAppOptionsType3Impl<ContractState>;
    impl OAppOptionsType3InternalImpl = OAppOptionsType3Component::InternalImpl<ContractState>;

    const LOCAL_DECIMALS: u8 = 6;
    const SHARED_DECIMALS: u8 = 6;
    // 10_000 mUSDC per faucet call (10_000 * 10^6).
    const FAUCET_CAP: u256 = 10000000000_u256;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        oapp_core: OAppCoreComponent::Storage,
        #[substorage(v0)]
        oft_core: OFTCoreComponent::Storage,
        #[substorage(v0)]
        oapp_options_type_3: OAppOptionsType3Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        OAppCoreEvent: OAppCoreComponent::Event,
        #[flat]
        OFTCoreEvent: OFTCoreComponent::Event,
        #[flat]
        OAppOptionsType3Event: OAppOptionsType3Component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        endpoint: ContractAddress,
        owner: ContractAddress,
        strk_token: ContractAddress,
    ) {
        self.erc20.initializer("Mock USDC", "mUSDC");
        self.ownable.initializer(owner);
        self.oapp_core.initializer(endpoint, owner, strk_token);
        self.oft_core.initializer(LOCAL_DECIMALS, SHARED_DECIMALS);
    }

    #[starknet::interface]
    pub trait IMockUsdcFaucet<TState> {
        fn faucet(ref self: TState, amount: u256);
        fn faucet_cap(self: @TState) -> u256;
    }

    #[abi(embed_v0)]
    impl FaucetImpl of IMockUsdcFaucet<ContractState> {
        fn faucet(ref self: ContractState, amount: u256) {
            assert(amount > 0_u256, 'amount=0');
            assert(amount <= FAUCET_CAP, 'over cap');
            let to = get_caller_address();
            self.erc20.mint(to, amount);
        }

        fn faucet_cap(self: @ContractState) -> u256 {
            FAUCET_CAP
        }
    }
}
