export const ROUTES = {
  home: '/',
  hostel: '/hostels/:id',
  roomType: '/hostels/:id/rooms/:type',
  login: '/login',
  terms: '/terms',
  queue: '/queue',
  claim: '/queue/claim',
  plan: '/checkout/plan',
  payer: '/checkout/payer',
  pay: '/checkout/pay',
  parentLink: '/checkout/parent-link',
  pending: '/checkout/pending',
  failed: '/checkout/failed',
  timeout: '/checkout/timeout',
  taken: '/checkout/taken',
  reservations: '/reservations',
  revoked: '/reservations/:id/revoked',
  parentPay: '/pay/:token',
} as const;

export type FlowState = 'none' | 'waiting' | 'claimable' | 'in_checkout' | 'awaiting_payment' | 'partially_booked' | 'booked';

export const ROUTE_FOR_STATE: Record<FlowState, string | null> = {
  none: null,
  waiting: ROUTES.queue,
  claimable: ROUTES.claim,
  in_checkout: ROUTES.plan,
  awaiting_payment: ROUTES.parentLink,
  partially_booked: ROUTES.reservations,
  booked: ROUTES.reservations,
};

export const TRANSITIONS = {
  RESERVE_CLICKED: {
    from: ROUTES.roomType,
    guest: ROUTES.login,
    authenticated: ROUTES.terms,
  },
  LOGGED_IN: {
    to: ROUTES.terms,
  },
  TERMS_ACCEPTED: {
    to: 'JOIN',
  },
  JOINED: {
    waiting: ROUTES.queue,
    claimable: ROUTES.claim,
  },
  TURN_OFFERED: ROUTES.claim,
  TURN_CLAIMED: ROUTES.plan,
  CLAIM_MISSED: ROUTES.timeout,
  ROOM_GONE: ROUTES.taken,
  PLAN_CHOSEN: ROUTES.payer,
  PAYER_SELF: ROUTES.pay,
  PAYER_PARENT: ROUTES.parentLink,
  PAYMENT_STARTED: ROUTES.pending,
  PAYMENT_CONFIRMED: ROUTES.reservations,
  PAYMENT_FAILED: ROUTES.failed,
  HOLD_EXPIRED: ROUTES.timeout,
  REJOIN: ROUTES.roomType,
  REVOKED: ROUTES.revoked,
} as const;
