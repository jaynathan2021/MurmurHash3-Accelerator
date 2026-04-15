vlib work

vlog ../rtl/*.sv
vlog ../tb/tb_murmurhash3.sv

vsim -voptargs=+acc tb_murmurhash3

add wave -r /*
run -all