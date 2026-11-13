## proxy configuration
rest-client configuration will have additional property:
 - proxy - optional, if specified it will have following properties: 
    url: string. required. must be in a form like http://myproxy.mycompany.com:8080 (port is optional)
    username: string. optional.
    password: string. optional. Not allowed if username is omitted.
    skip-certificate-validation: boolean, default false. If true then it will configure the rest-client to skip certificate validation of the proxy server. Investigate if this will also skip certificate validation of the actual api endpoints and if it does make sure to add this to documentation. Indicate that this option is rarely needed but can be useful if the proxy server itself uses https endpoint with a self-signed or corporate certificate.

Support for HTTP_PROXY or HTTPS_PROXY environment variables. If these variables are set then they will NOT override the rest-client configuration. The configuration or proxy in the rest-client takes presenense over the environment variables by default. To override this bevaviour set another environment variable from environment or from .env file (link to .env file configuration here) with the name "PROXY_USE_ENV" with value of true. If this is set the HTTP_PROXY or HTTPS_PROXY will override the rest-client configuration. 

Implement all these proxy configuration override from environment logic in the cmdrest-web documentation.

If proxy configuration is present then programmatically add it to rest-client when rest-client is being created. Based on the protocol in the url (http or https) create appropriate configuration for the rest-client proxy. Our rest-client always uses Jdk Client, so only target the JDK client.

When requests go through a proxy, they must be authenticated if the proxy requires authentication. Add logging at info level to indicate that a request is going through a proxy. Always mask username/password in the log when logging creation of proxy service.

Update README.md to indicate that requests can optionally use a proxy.
Update the schema for test suite yaml file.

In cmdrest web create documentation page for "requests through a proxy"
Indicate that this configuration is optional and only used if you are behind a proxy server like a corporate proxy.
Emphasize that username and password for proxy should use environment variables and use the template placeholders and to never add username/password to the test suite yaml file.
Create an example of rest-client with proxy configuration that users costom domain, custom port, username and password.

Make sure to add a link to this page from the navigation.

Add a tile to 'features' page to indicate that requests can optionally use a proxy.

When making requests through a proxy, make best effort to detect errors related specifically to a proxy server and use these errors as an error in the failed tests so that they can be shown in TUI and in report.

Always log proxy related errors to the log when logging is enabled.
