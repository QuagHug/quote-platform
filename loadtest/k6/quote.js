import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://host.docker.internal:8080';
const PEAK = Number(__ENV.PEAK_RPS || 10);

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 2,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 300,
      stages: [
        { target: 2, duration: '1m' },
        { target: PEAK, duration: '3m' },
      ],
      tags: { phase: 'ramp' },
    },
    hold: {
      executor: 'constant-arrival-rate',
      rate: PEAK,
      timeUnit: '1s',
      duration: '5m',
      startTime: '4m',
      preAllocatedVUs: 50,
      maxVUs: 300,
      tags: { phase: 'hold' },
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
    // Latency is gated only once the HPA has caught up; the ramp measures reaction time.
    'http_req_duration{phase:hold}': ['p(95)<1000', 'p(99)<2500'],
    'http_req_duration{phase:ramp}': ['p(95)<100000'],
  },
};

export default function () {
  const res = http.get(`${BASE}/api/quote`);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'body has a quote': (r) => r.status === 200 && r.json('quote') !== undefined,
  });
}
