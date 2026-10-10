import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://host.docker.internal:8080';
const STEPS = (__ENV.STEPS || '10,15,20,25,30').split(',').map(Number);

export const options = {
  scenarios: Object.fromEntries(STEPS.map((rate, i) => [`rps_${rate}`, {
    executor: 'constant-arrival-rate', rate, timeUnit: '1s', duration: '90s',
    startTime: `${i * 100}s`, preAllocatedVUs: 50, maxVUs: 300, tags: { step: String(rate) },
  }])),
  summaryTrendStats: ['med', 'p(95)', 'p(99)'],
  // Never-failing thresholds, only so the summary prints each step's tagged metrics.
  thresholds: Object.fromEntries(STEPS.flatMap((r) => [
    [`http_req_duration{step:${r}}`, ['p(95)<100000']],
    [`dropped_iterations{step:${r}}`, ['count<100000']],
  ])),
};

export default function () {
  check(http.get(`${BASE}/api/quote`), { 'status is 200': (r) => r.status === 200 });
}
