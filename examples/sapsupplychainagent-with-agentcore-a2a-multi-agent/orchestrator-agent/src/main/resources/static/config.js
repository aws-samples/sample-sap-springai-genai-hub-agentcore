// Configuration management
let globalConfig = null;

function isLocalhost() {
    const hostname = window.location.hostname;
    const path = window.location.pathname;
    return hostname === 'localhost'
        || hostname === '127.0.0.1'
        || path.startsWith('/ports/');  // CloudFront dev proxy
}

async function loadConfig() {
    if (globalConfig) return globalConfig;

    try {
        const response = await fetch('config.json');
        if (response.ok) {
            globalConfig = await response.json();
        }
    } catch (error) {
        // Use defaults
    }

    if (!globalConfig) {
        globalConfig = {};
    }

    if (globalConfig.userPoolId && globalConfig.clientId) {
        globalConfig.mode = 'aws';
        globalConfig.authType = 'cognito';
    } else {
        // No Cognito configured — use simple auth (username sent as Authorization header).
        // Works both locally and when deployed without a Cognito user pool.
        globalConfig.mode = isLocalhost() ? 'local' : 'aws';
        globalConfig.authType = 'simple';
    }

    return globalConfig;
}

function getApiEndpoint(config) {
    return config.apiEndpoint || 'invocations';
}

function isAttachmentsEnabled(config) {
    return config && config.enableAttachments === true;
}
