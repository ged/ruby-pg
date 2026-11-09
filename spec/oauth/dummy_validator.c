#include "postgres.h"
#include "fmgr.h"
#include "libpq/oauth.h"

PG_MODULE_MAGIC;

static bool
validate_token(const ValidatorModuleState *state,
			   const char *token, const char *role,
			   ValidatorModuleResult *res)
{
	if (strcmp(token, "yes") == 0)
	{
		res->authorized = true;
		res->authn_id = pstrdup(role);
	}
	return true;
}

static const OAuthValidatorCallbacks validator_callbacks = {
	PG_OAUTH_VALIDATOR_MAGIC,
	.validate_cb = validate_token
};

const OAuthValidatorCallbacks *
_PG_oauth_validator_module_init(void)
{
	return &validator_callbacks;
}
