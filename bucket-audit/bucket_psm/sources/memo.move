module bucket_v2_psm::memo {
    use std::string::String;

    public fun swap_in(): String { b"psm_swap_in".to_string() }

    public fun swap_out(): String { b"psm_swap_out".to_string() }
}
