#[path = "../../benches/utilities.rs"]
mod utilities;

use crate::utilities::{write_to_json, OperatorType};
use clap::Parser;
use std::collections::HashMap;
use std::fs;

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;
use tfhe::shortint::keycache::NamedParam;
use tfhe::shortint::parameters::{
    PARAM_MESSAGE_2_CARRY_2_COMPACT_PK, PARAM_SMALL_MESSAGE_2_CARRY_2_COMPACT_PK,
};
use tfhe::shortint::ClassicPBSParameters;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    raw_results_dir: String,
}

fn params_from_name(name: &str) -> ClassicPBSParameters {
    match name.to_lowercase().as_str() {
        "param_message_2_carry_2_compact_pk" => PARAM_MESSAGE_2_CARRY_2_COMPACT_PK,
        "param_small_message_2_carry_2_compact_pk" => PARAM_SMALL_MESSAGE_2_CARRY_2_COMPACT_PK,
        _ => panic!("failed to get parameters for name '{name}'"),
    }
}

fn write_result(file: &mut File, name: &str, value: usize) {
    let line = format!("{name},{value}\n");
    let error_message = format!("cannot write {name} result into file");
    file.write_all(line.as_bytes()).expect(&error_message);
}

pub fn parse_wasm_benchmarks(results_file: &Path, raw_results_dir: &Path) {
    File::create(results_file).expect("create results file failed");
    let mut file = OpenOptions::new()
        .append(true)
        .open(results_file)
        .expect("cannot open parsed results file");

    let operator = OperatorType::Atomic;

    for entry in raw_results_dir
        .read_dir()
        .expect("cannot read results directory")
        .flatten()
    {
        let raw_results = fs::read_to_string(entry.path()).expect("cannot open raw results file");
        let results_as_json: HashMap<String, f32> = serde_json::from_str(&raw_results).unwrap();

        for (full_name, val) in results_as_json.iter() {
            let name_parts = full_name.split("_mean_").collect::<Vec<_>>();
            let bench_name = name_parts[0];
            let params = params_from_name(name_parts[1]);
            let value_in_ns = (val * 1_000_000_f32) as usize;

            write_result(&mut file, full_name, value_in_ns);
            write_to_json(
                full_name,
                params,
                params.name(),
                bench_name,
                &operator,
                0,
                vec![],
            );
        }
    }
}

fn main() {
    let args = Args::parse();

    let work_dir = std::env::current_dir().unwrap();
    let mut new_work_dir = work_dir;
    new_work_dir.push("tfhe");
    std::env::set_current_dir(new_work_dir).unwrap();

    let results_file = Path::new("wasm_pk_gen.csv");
    let raw_results_dir = Path::new(&args.raw_results_dir);

    parse_wasm_benchmarks(results_file, raw_results_dir);
}