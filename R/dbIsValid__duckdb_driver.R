#' @rdname duckdb_driver-class
#' @inheritParams DBI::dbIsValid
#' @usage NULL
dbIsValid__duckdb_driver <- function(dbObj, ...) {
  valid <- FALSE
  tryCatch(
    {
      was_locked <- rethrow_rapi_is_locked(dbObj@database_ref)
      con <- dbConnect(dbObj)
      # Keep driver alive, but only if needed
      if (was_locked) {
        rethrow_rapi_lock(dbObj@database_ref)
      }

      dbExecute(con, SQL("SELECT 1"))
      dbDisconnect(con)
      valid <- TRUE
    },
    error = function(c) {
    }
  )
  valid
}

#' @rdname duckdb_driver-class
#' @export
setMethod("dbIsValid", "duckdb_driver", dbIsValid__duckdb_driver)
