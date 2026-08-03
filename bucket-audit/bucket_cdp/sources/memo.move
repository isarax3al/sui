module bucket_v2_cdp::memo;

use std::string::{String};

public fun manage(): String { b"cdp_manage".to_string() }

public fun donate(): String { b"cdp_donate".to_string() }

public fun liquidate(): String { b"cdp_liquidate".to_string() }

public fun interest(): String { b"cdp_interest".to_string() }
