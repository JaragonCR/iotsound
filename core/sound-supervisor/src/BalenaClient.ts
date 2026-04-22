import { getSdk, BalenaSDK } from 'balena-sdk'

const sdk: BalenaSDK = getSdk({ apiUrl: 'https://api.balena-cloud.com/' })
sdk.auth.logout()
sdk.auth.loginWithToken(process.env.BALENA_API_KEY!) // Asserted by io.balena.features.balena-api: '1'

export default sdk
