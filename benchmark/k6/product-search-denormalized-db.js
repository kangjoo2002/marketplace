import http from 'k6/http';
import { check, fail } from 'k6';
import { Trend } from 'k6/metrics';

export const SCENARIO_SET_NAME = 'product-search-baseline-v1';

const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8080').replace(/\/$/, '');
// PROFILE is k6 metadata/tagging only; the denormalized DB API reads the fixed moderate_skew read table.
const PROFILE = __ENV.PROFILE || 'moderate_skew';
const VUS = Number(__ENV.VUS || 10);
const DURATION = __ENV.DURATION || '1m';
const SMOKE_ONLY = (__ENV.SMOKE_ONLY || 'false').toLowerCase() === 'true';
const ENDPOINT = '/api/v1/products/search/denormalized-db';

const b1Duration = new Trend('b1_selective_option_filter_duration', true);
const b2Duration = new Trend('b2_broad_active_option_filter_duration', true);
const b3Duration = new Trend('b3_deep_offset_option_filter_duration', true);
const b1ReturnedCount = new Trend('b1_selective_option_filter_returned_count');
const b2ReturnedCount = new Trend('b2_broad_active_option_filter_returned_count');
const b3ReturnedCount = new Trend('b3_deep_offset_option_filter_returned_count');

const READ_TABLE_INDEXES = [
  'idx_psd_moderate_skew_active_cat_brand_review',
  'idx_psd_moderate_skew_active_created',
  'idx_psd_moderate_skew_option_signatures_gin',
];

const REQUEST_SCENARIOS = [
  {
    name: 'B1_selective_option_filter',
    weight: 40,
    purpose: 'Selective category and brand product search with price and option filters.',
    trend: b1Duration,
    returnedCountTrend: b1ReturnedCount,
    params: {
      categoryId: '75',
      brandId: '943',
      status: 'ACTIVE',
      minPrice: '10000',
      maxPrice: '100000',
      color: 'BLACK',
      size: 'M',
      stockStatus: 'IN_STOCK',
      sort: 'reviewCountDesc',
      limit: '50',
      offset: '100',
    },
  },
  {
    name: 'B2_broad_active_option_filter',
    weight: 40,
    purpose: 'Broad active-product option filter with latest-created ordering.',
    trend: b2Duration,
    returnedCountTrend: b2ReturnedCount,
    params: {
      status: 'ACTIVE',
      color: 'BLACK',
      size: 'M',
      stockStatus: 'IN_STOCK',
      sort: 'createdAtDesc',
      limit: '50',
      offset: '100',
    },
  },
  {
    name: 'B3_deep_offset_option_filter',
    weight: 20,
    purpose: 'Deeper page of the same selective category and brand product search as B1.',
    trend: b3Duration,
    returnedCountTrend: b3ReturnedCount,
    params: {
      categoryId: '75',
      brandId: '943',
      status: 'ACTIVE',
      minPrice: '10000',
      maxPrice: '100000',
      color: 'BLACK',
      size: 'M',
      stockStatus: 'IN_STOCK',
      sort: 'reviewCountDesc',
      limit: '50',
      offset: '10000',
    },
  },
];

const WEIGHTED_SEQUENCE = [
  REQUEST_SCENARIOS[0],
  REQUEST_SCENARIOS[0],
  REQUEST_SCENARIOS[1],
  REQUEST_SCENARIOS[1],
  REQUEST_SCENARIOS[2],
];

export const options = SMOKE_ONLY
  ? {
      scenarios: {
        scenario_smoke_validation: {
          executor: 'shared-iterations',
          vus: 1,
          iterations: REQUEST_SCENARIOS.length,
          maxDuration: '1m',
        },
      },
      thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
      },
    }
  : {
      scenarios: {
        product_search_baseline_v1: {
          executor: 'constant-vus',
          vus: VUS,
          duration: DURATION,
          gracefulStop: '10s',
        },
      },
      thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
      },
    };

export default function () {
  const scenario = SMOKE_ONLY
    ? REQUEST_SCENARIOS[__ITER % REQUEST_SCENARIOS.length]
    : WEIGHTED_SEQUENCE[__ITER % WEIGHTED_SEQUENCE.length];

  runScenario(scenario);
}

function runScenario(scenario) {
  const query = Object.entries(scenario.params)
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join('&');
  const url = `${BASE_URL}${ENDPOINT}?${query}`;

  const response = http.get(url, {
    tags: {
      scenario_set: SCENARIO_SET_NAME,
      request_scenario: scenario.name,
      profile: PROFILE,
      read_path: 'denormalized_db_api',
    },
  });

  scenario.trend.add(response.timings.duration);

  let body = null;
  try {
    body = response.json();
  } catch (error) {
    body = null;
  }

  const limit = Number(scenario.params.limit);
  const offset = Number(scenario.params.offset);
  if (body && body.page && typeof body.page.returnedCount === 'number') {
    scenario.returnedCountTrend.add(body.page.returnedCount);
  }

  const passed = check(response, {
    [`${scenario.name}: HTTP 200`]: (r) => r.status === 200,
    [`${scenario.name}: items is an array`]: () => Array.isArray(body && body.items),
    [`${scenario.name}: items length equals limit`]: () =>
      Array.isArray(body && body.items) && body.items.length === limit,
    [`${scenario.name}: page exists`]: () => Boolean(body && body.page),
    [`${scenario.name}: page.limit matches request`]: () => body && body.page && body.page.limit === limit,
    [`${scenario.name}: page.offset matches request`]: () => body && body.page && body.page.offset === offset,
    [`${scenario.name}: returnedCount is a number`]: () =>
      body && body.page && typeof body.page.returnedCount === 'number',
    [`${scenario.name}: returnedCount > 0`]: () =>
      body && body.page && typeof body.page.returnedCount === 'number' && body.page.returnedCount > 0,
    [`${scenario.name}: returnedCount equals limit`]: () =>
      body && body.page && typeof body.page.returnedCount === 'number' && body.page.returnedCount === limit,
    [`${scenario.name}: returnedCount <= limit`]: () =>
      body && body.page && typeof body.page.returnedCount === 'number' && body.page.returnedCount <= limit,
  });

  if (!passed) {
    fail(`${scenario.name} failed Denormalized DB API response validation`);
  }
}

export function handleSummary(data) {
  const enrichedSummary = {
    benchmark: {
      scenarioSetName: SCENARIO_SET_NAME,
      workloadVersion: SCENARIO_SET_NAME,
      profile: PROFILE,
      baseUrl: BASE_URL,
      vus: SMOKE_ONLY ? 1 : VUS,
      duration: SMOKE_ONLY ? 'smoke' : DURATION,
      smokeOnly: SMOKE_ONLY,
      readPath: 'Denormalized DB API',
      endpoint: ENDPOINT,
      queryShape: 'PostgreSQL product_search_documents_moderate_skew read table, option_signatures filter, OFFSET pagination',
      readTable: 'product_search_documents_moderate_skew',
      readTableIndexes: READ_TABLE_INDEXES,
      notes: [
        'Denormalized DB API reads the PostgreSQL read table, not OpenSearch.',
        'B3 deep OFFSET remains part of the unchanged benchmark workload.',
        'PROFILE is k6 metadata/tagging only for this fixed moderate_skew read table benchmark.',
      ],
    },
    requestScenarios: REQUEST_SCENARIOS.map(({ name, weight, purpose, params }) => ({
      name,
      weight,
      purpose,
      params,
    })),
    summary: data,
  };

  const stdout = [
    `${SCENARIO_SET_NAME}`,
    `read_path=Denormalized DB API`,
    `profile=${PROFILE}`,
    `baseUrl=${BASE_URL}`,
    `endpoint=${ENDPOINT}`,
    `http_req_duration p95=${metricValue(data, 'http_req_duration', 'p(95)')} ms`,
    `throughput=${metricValue(data, 'http_reqs', 'rate')} req/s`,
    `error_rate=${metricValue(data, 'http_req_failed', 'rate')}`,
    `failed_checks=${metricValue(data, 'checks', 'fails')}`,
    `total_requests=${metricValue(data, 'http_reqs', 'count')}`,
    `b1_selective_option_filter_duration p95=${metricValue(data, 'b1_selective_option_filter_duration', 'p(95)')} ms`,
    `b2_broad_active_option_filter_duration p95=${metricValue(data, 'b2_broad_active_option_filter_duration', 'p(95)')} ms`,
    `b3_deep_offset_option_filter_duration p95=${metricValue(data, 'b3_deep_offset_option_filter_duration', 'p(95)')} ms`,
    '',
  ].join('\n');

  const outputs = {
    stdout,
  };

  if (__ENV.SUMMARY_JSON) {
    outputs[__ENV.SUMMARY_JSON] = JSON.stringify(enrichedSummary, null, 2);
  }

  return outputs;
}

function metricValue(data, metricName, valueName) {
  const metric = data.metrics && data.metrics[metricName];
  if (!metric || !metric.values || metric.values[valueName] === undefined) {
    return 'N';
  }
  return metric.values[valueName];
}
