# Tempo Operational (mixin compilado): Tempo roda monolítico (um job só).
include "_lib";
drop_vars(["namespace"])
| single_binary("tempo")
