// Authentication management
const AUTH_KEY = 'agentcore_auth';
const SESSION_KEY = 'agentcore_session_id';

let currentAuth = null;

/**
 * Generates a stable session ID per browser login.
 * This is sent as X-Amzn-Bedrock-AgentCore-Runtime-Session-Id — the AgentCore
 * system header that controls microVM session routing and the session.id
 * attribute on all OTEL spans. AgentCore evaluations use session.id to
 * correlate all spans within a conversation session.
 *
 * The value must be ≥33 characters (AgentCore API requirement).
 */
function generateSessionId(username) {
    return username + '-' + crypto.randomUUID();
}

function getSessionId() {
    return sessionStorage.getItem(SESSION_KEY);
}

function saveAuth(auth) {
    localStorage.setItem(AUTH_KEY, JSON.stringify(auth));
    currentAuth = auth;

    // Generate a new session ID per login — stored in sessionStorage so it
    // persists across page refreshes but resets on new browser tab/login.
    if (!sessionStorage.getItem(SESSION_KEY)) {
        sessionStorage.setItem(SESSION_KEY, generateSessionId(auth.username));
    }
}

function loadAuth() {
    if (currentAuth) return currentAuth;
    const saved = localStorage.getItem(AUTH_KEY);
    if (saved) {
        currentAuth = JSON.parse(saved);
    }
    return currentAuth;
}

function clearAuth() {
    localStorage.removeItem(AUTH_KEY);
    sessionStorage.removeItem(SESSION_KEY);
    currentAuth = null;
}

function isAuthenticated() {
    const auth = loadAuth();
    if (!auth || !auth.accessToken || !auth.expiresAt) {
        return false;
    }
    // 5 minute buffer before expiry
    return Date.now() < (auth.expiresAt - 300000);
}

async function authenticateUser(username, password, config) {
    if (config.authType === 'cognito') {
        return authenticateCognito(username, password, config);
    }
    return authenticateSimple(username, password);
}

async function authenticateSimple(username, password) {
    if (!username || username.trim() === '') {
        throw new Error('Username is required');
    }

    const auth = {
        username: username,
        accessToken: 'local-dev-token',
        idToken: 'local-dev-token',
        expiresAt: Date.now() + (24 * 60 * 60 * 1000), // 24 hours
        authType: 'simple'
    };

    saveAuth(auth);
    return auth;
}

async function authenticateCognito(username, password, config) {
    if (typeof AmazonCognitoIdentity === 'undefined') {
        await new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = 'https://cdn.jsdelivr.net/npm/amazon-cognito-identity-js@6.3.6/dist/amazon-cognito-identity.min.js';
            script.onload = resolve;
            script.onerror = () => reject(new Error('Failed to load Cognito SDK'));
            document.head.appendChild(script);
        });
    }

    const normalizedUsername = username.toLowerCase().trim();

    const poolData = {
        UserPoolId: config.userPoolId,
        ClientId: config.clientId
    };

    const userPool = new AmazonCognitoIdentity.CognitoUserPool(poolData);
    const authenticationDetails = new AmazonCognitoIdentity.AuthenticationDetails({
        Username: normalizedUsername,
        Password: password
    });
    const cognitoUser = new AmazonCognitoIdentity.CognitoUser({
        Username: normalizedUsername,
        Pool: userPool
    });

    return new Promise((resolve, reject) => {
        cognitoUser.authenticateUser(authenticationDetails, {
            onSuccess: function(result) {
                const accessToken = result.getAccessToken().getJwtToken();
                const idToken = result.getIdToken().getJwtToken();
                const expiresAt = Date.now() + (result.getAccessToken().getExpiration() * 1000);
                const payload = JSON.parse(atob(accessToken.split('.')[1]));

                const auth = {
                    username: payload.username || username,
                    accessToken: accessToken,
                    idToken: idToken,
                    expiresAt: expiresAt,
                    authType: 'cognito'
                };

                saveAuth(auth);
                resolve(auth);
            },
            onFailure: function(err) {
                reject(err);
            },
            newPasswordRequired: function() {
                reject(new Error('New password required. Please use AWS Console to set a new password.'));
            }
        });
    });
}
