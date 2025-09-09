import cf from 'cloudfront';

// This fails if there is no key value store associated with the function
const kvsHandle = cf.kvs();

// Constants
const ENV_NAME = 'dev';
const ENV_DOT = '.';
const DOMAIN = 'verihire.cc';

const API_DEMO_KEY = 'XYZ123XYZ123';
const API_SUBSCRIPTIONS_KEY = 'XYZ123XYZ123';

const ORIGINS = {
    'blue_api': `blue-api.${ENV_NAME}${ENV_DOT}${DOMAIN}`,
    'green_api': `green-api.${ENV_NAME}${ENV_DOT}${DOMAIN}`,
    'blue_app': `blue-app.${ENV_NAME}${ENV_DOT}${DOMAIN}`,
    'green_app': `green-app.${ENV_NAME}${ENV_DOT}${DOMAIN}`,
    'subscriptions': `subscriptions.${ENV_NAME}${ENV_DOT}${DOMAIN}`
};

function hashIp(ip) {
    // Simple hash function that mimics the Python MD5 hash mod 100
    let hash = 0;
    for (let i = 0; i < ip.length; i++) {
        hash = ((hash << 5) - hash) + ip.charCodeAt(i);
        hash = hash & hash;
    }
    return Math.abs(hash % 100);
}

function getCookieValue(cookies, cookieName) {
    if (!cookies) return null;
    
    const cookieList = cookies.split(';');
    for (let i = 0; i < cookieList.length; i++) {
        const cookie = cookieList[i];
        const parts = cookie.trim().split('=');
        const name = parts[0];
        const value = parts[1];
        if (name === cookieName) {
            return value;
        }
    }
    return null;
}

async function handler(event) {
    const request = event.request;
    const clientIp = event.viewer.ip;
    const headers = request.headers;
    const uri = request.uri;
    let userHash = 'N/A';

    // Handle redirect logic from / to /app
    if (uri === '/') {
        return {
            statusCode: 302,
            statusDescription: 'Found',
            headers: {
                'location': {
                    value: `https://${ENV_NAME}${ENV_DOT}${DOMAIN}/app`
                }
            }
        };
    }

    // Step 1: Determine routing based on the path
    let routeType = 'app';
    if (['/index.html', '/favicon.ico', '/robots.txt', '/sitemap.xml', 
         '/llms.txt', '/llms-full.txt', '/web-app-manifest-512x512.png', 
         '/web-app-manifest-192x192.png'].includes(uri)) {
        routeType = 'app';
        request.uri = '/app' + uri;
    } else if (uri.startsWith('/api')) {
        routeType = 'api';
    } else if (uri.startsWith('/subscriptions')) {
        routeType = 'subscriptions';
    }

    // Step 2: Check cookies specific to the route type
    let colorCookie, originBlue, originGreen;
    if (routeType === 'api') {
        colorCookie = getCookieValue(headers.cookie ? headers.cookie.value : null, `X-${DOMAIN.toUpperCase()}-API-COLOR`);
        originBlue = 'blue_api';
        originGreen = 'green_api';
    } else if (routeType === 'subscriptions') {
        colorCookie = getCookieValue(headers.cookie ? headers.cookie.value : null, `X-${DOMAIN.toUpperCase()}-SUBSCRIPTIONS-COLOR`);
        originBlue = 'subscriptions';
        originGreen = 'subscriptions';
    } else {
        colorCookie = getCookieValue(headers.cookie ? headers.cookie.value : null, `X-${DOMAIN.toUpperCase()}-APP-COLOR`);
        originBlue = 'blue_app';
        originGreen = 'green_app';
    }

    if (colorCookie === 'blue' || colorCookie === 'green') {
        // Route based on the color cookie for the relevant system
        const route = colorCookie === 'blue' ? originBlue : originGreen;

        // Set API keys for demo rate limiting
        if (uri.includes('/api/ui/v1/demo')) {
            request.headers['x-api-key'] = { value: API_DEMO_KEY };
        }

        if (uri.includes('/subscriptions')) {
            request.headers['x-api-key'] = { value: API_SUBSCRIPTIONS_KEY };
        }

        // Set API keys for external
        if (uri.includes('/api/external/v1')) {
            const extApiKeyHeader = headers[`x-${DOMAIN.toLowerCase()}-ext-api-key`];
            const extApiKey = extApiKeyHeader ? extApiKeyHeader.value : null;
            if (extApiKey) {
                request.headers['x-api-key'] = { value: extApiKey };
            }
        }

        request.headers.host = { value: ORIGINS[route] };
        console.log(`Routing to ${route} based on cookie: ${colorCookie}`);
        console.log(`Client IP: ${clientIp}, Hash: N/A, Weight: N/A, Route: ${route}, URI: ${request.uri}`);
        
        return request;
    }

    // Step 3: If no cookie is set, determine routing dynamically based on IP hash and weight
    const routingKey = `routing-${routeType}`;
    let info = { weight: 51, green: 'unknown', blue: 'unknown' }; // Default value
    
    try {
        const routingInfo = await kvsHandle.get(routingKey);
        if (routingInfo) {
            // console.log(`routingInfo: ${routingInfo}`);
            try {
                // Convert Python-style single quotes to JSON-compatible double quotes
                const jsonString = routingInfo.replace(/'/g, '"');
                info = JSON.parse(jsonString);
            } catch (e) {
                console.error(`Error parsing routing info for ${routingKey}: ${e.message || e}`);
            }
        } else {
            console.log(`No routing info found for ${routingKey}`);
        }
    } catch (err) {
        console.log(`Kvs key lookup failed for ${routingKey}: ${err.message || err}`);
    }

    const weight = info.weight;
    const colorVersion = weight > 50 ? info.green : info.blue;
    let route;

    if (weight === 0) {
        route = originBlue;
    } else if (weight === 100) {
        route = originGreen;
    } else {
        userHash = hashIp(clientIp);
        route = userHash > weight ? originBlue : originGreen;
    }

    // Set API keys for demo rate limiting
    if (uri.includes('/api/ui/v1/demo')) {
        request.headers['x-api-key'] = { value: API_DEMO_KEY };
    }

    if (uri.includes('/subscriptions')) {
        console.log('Setting x-api-key for subscriptions');
        request.headers['x-api-key'] = { value: API_SUBSCRIPTIONS_KEY };
    }

    // Set API keys for external
    if (uri.includes('/api/external/v1')) {
        const extApiKeyHeader = headers[`x-${DOMAIN.toLowerCase()}-ext-api-key`];
        const extApiKey = extApiKeyHeader ? extApiKeyHeader.value : null;
        if (extApiKey) {
            request.headers['x-api-key'] = { value: extApiKey };
        }
    }

    // Update the host header
    // request.headers.host = { value: ORIGINS[route] };
    cf.updateRequestOrigin({
        "domainName" : ORIGINS[route]
    });

    // Allow us to pass in x-country for testing purposes
    if (!headers['x-country']) {
        const viewerCountry = headers['cloudfront-viewer-country'];
        request.headers['x-country'] = { value: viewerCountry && viewerCountry.value ? viewerCountry.value : '' };
    }

    // Allow us to pass x-auth-header to lambdas behind other cloudfronts
    const authHeader = headers.authorization;
    if (authHeader && authHeader.value && !headers[`x-${DOMAIN.toLowerCase()}-auth`]) {
        request.headers[`x-${DOMAIN.toLowerCase()}-auth`] = { value: authHeader.value };
    }

    // Log for debugging
    console.log(`Client IP: ${clientIp}, Hash: ${userHash}, Weight: ${weight}, Route: ${route}, URI: ${request.uri}`);

    return request;
} 