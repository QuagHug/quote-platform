// Ramps request rate against /api/quote through the Ingress (Traefik).
// Thresholds come from the baseline measured in LOADTEST.md, not generic numbers.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://host.docker.internal:8080';
const PEAK = Number(__ENV.PEAK_RPS || 20);

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',   // fixed request rate, so latency can't hide load
      startRate: 2,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 400,
      stages: [
        { target: 2, duration: '1m' },          // baseline: what one request costs
        { target: PEAK / 2, duration: '2m' },
        { target: PEAK, duration: '2m' },
        { target: PEAK, duration: '4m' },       // hold: HPA catches up, latency settles
        { target: 0, duration: '1m' },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{expected_response:true}': ['p(95)<1500', 'p(99)<3000'],
    checks: ['rate>0.99'],
  },
};

export default function () {
  const res = http.get(`${BASE}/api/quote`, { tags: { name: '/api/quote' } });
  check(res, {
    'status is 200': (r) => r.status === 200,
    'body has a quote': (r) => r.status === 200 && r.json('quote') !== undefined,
  });
}
