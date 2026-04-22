import logging

import jwt
from oic.extension.message import TokenIntrospectionRequest, TokenIntrospectionResponse
from oic.oic import Client
from oic.oic.message import RegistrationResponse
from oic.utils.authn.client import CLIENT_AUTHN_METHOD

log = logging.getLogger(__name__)


class OIDCmanager:
    """
    Class that interfaces with PyOIDC

    It is supposed to have a unique instance which provides all operations that require
    information from the OIDC issuers.
    """

    def __init__(self):
        self.clients = {}
        self.config = None

    def setup(self, config):
        self.config = config
        self._configure_clients(config["fts3.Providers"])
        self._set_keys_cache_time(config["fts3.JWKCacheSeconds"])
        self._retrieve_clients_keys()

    def _configure_clients(self, providers_config):
        for provider in providers_config:
            try:
                client = Client(client_authn_method=CLIENT_AUTHN_METHOD)
                # Retrieve well-known configuration
                client.provider_config(provider)
                # Register
                client_reg = RegistrationResponse(
                    client_id=providers_config[provider]["client_id"],
                    client_secret=providers_config[provider]["client_secret"],
                )
                client.store_registration_info(client_reg)
                issuer = client.provider_info["issuer"]
                if "introspection_endpoint" not in client.provider_info:
                    log.info("{} -- missing introspection endpoint".format(issuer))
                self.clients[issuer] = client
            except Exception as ex:
                log.warning("Exception registering provider: {}".format(provider))
                log.warning(ex)

    def _retrieve_clients_keys(self):
        for provider in self.clients:
            client = self.clients[provider]
            client.keyjar.get_issuer_keys(provider)

    def _set_keys_cache_time(self, cache_time):
        for provider in self.clients:
            client = self.clients[provider]
            keybundles = client.keyjar.issuer_keys[provider]
            for keybundle in keybundles:
                keybundle.cache_time = cache_time

    def get_token_issuer(self, access_token):
        unverified_payload = jwt.decode(access_token, options=jwt_options_unverified())
        issuer = unverified_payload["iss"]
        # Return issuer as-is ? no trailing slash normalization.
        # self.clients is keyed by what Keycloak's discovery endpoint returns
        # (no trailing slash), so we must not add one here.
        return issuer

    def token_issuer_supported(self, access_token):
        """
        Given an access token, checks whether a client is registered
        for the token issuer.
        :param access_token:
        :return: true if token issuer is supported, false otherwise
        :raise KeyError: issuer claim missing
        """
        issuer = self.get_token_issuer(access_token)
        log.debug("Checking client registration for issuer={}".format(issuer))
        log.debug("Supported issuers={}".format(list(self.clients.keys())))
        return issuer in self.clients

    def filter_provider_keys(self, issuer, kid=None, alg=None):
        """
        Return Provider Keys after applying Key ID and Algorithm filter.
        If no filters match, return the full set.
        :param issuer: provider
        :param kid: Key ID
        :param alg: Algorithm
        :return: keys
        :raise ValueError: client could not be retrieved
        """
        client = self.clients.get(issuer)
        if client is None:
            raise ValueError("Could not retrieve client for issuer={}".format(issuer))
        # List of Keys (from pyjwkest)
        keys = client.keyjar.get_issuer_keys(issuer)
        filtered_keys = [key for key in keys if key.kid == kid or key.alg == alg]
        if len(filtered_keys) == 0:
            return keys
        return filtered_keys

    def introspect(self, issuer, access_token):
        """
        Make a Token Introspection request
        :param issuer: issuer of the token
        :param access_token: token to introspect
        :return: JSON response
        """
        client = self.clients.get(issuer)
        if client is None:
            raise ValueError("Could not retrieve client for issuer={}".format(issuer))
        if "introspection_endpoint" not in client.provider_info:
            raise Exception("Issuer does not support introspection")
        response = client.do_any(
            request_args={"token": access_token},
            request=TokenIntrospectionRequest,
            response=TokenIntrospectionResponse,
            body_type="json",
            method="POST",
            authn_method="client_secret_basic",
        )
        return response

    @staticmethod
    def jwt_options_unverified(options=None):
        options_unverified = {
            "verify_signature": False,
            "verify_exp": False,
            "verify_nbf": False,
            "verify_iat": False,
            "verify_aud": False,
            "verify_iss": False,
        }
        if options is not None:
            options_unverified.update(options)
        return options_unverified


# Should be the only instance, called during the middleware initialization
oidc_manager = OIDCmanager()
jwt_options_unverified = OIDCmanager.jwt_options_unverified
