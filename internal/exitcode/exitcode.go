package exitcode

const (
	OK                    = 0
	InvalidInput          = 2
	UnavailableDependency = 3
	DriftDetected         = 4
	BlockedOperation      = 5
	PartialFailure        = 6
	NotFound              = 7
	InternalError         = 70
)
