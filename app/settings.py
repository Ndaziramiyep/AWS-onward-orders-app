"""Release settings for the Onward Orders app. Change a value, push to main, and it ships."""

# Shown on the home page (lab requirement: full name and lab name).
STUDENT_NAME = "Patrick Ndaziramiye"
LAB_NAME = "Delivering Order System Updates Safely"

# Free text shown on the page; edit it to demo a visible new release.
RELEASE_NOTE = "Initial release"

# Bad-release demo: set True and push, and /health returns 500. The new (green) tasks never
# become healthy, the unhealthy-host alarm fires, and CodeDeploy rolls back automatically while
# the old (blue) tasks keep serving customers. Keep False for normal releases.
FORCE_UNHEALTHY = False
