#!/usr/bin/env python3

### based on Perl script stutterSim.pl

__author__ = "Katarzyna Kedzierska"
__email__ = "kzk5f@virginia.edu"

import logging
import cython
from math import e as e_const
from itertools import repeat, chain, product
import numpy as np
import pandas as pd
from sklearn.metrics import r2_score
from scipy.special import binom
from scipy.stats import multinomial, mannwhitneyu
from pymc.distributions import multivariate_hypergeometric_like as mhl
cimport numpy as np
DTYPE = np.int
ctypedef np.int_t DTYPE_t

# cython: linetrace=True

# FUNCTIONS RUN ONLY ONCE/TWICE PER GENOTYPE
def get_alleles(genot_input):
    """get a dictionary with alleles as keys and number_of_reads  as values from the genotype ('allele1|#;allele2|#').
    """
    max_allele = max([int(v[0]) for v in [f.split('|') for f in genot_input.split(';')]]) * 25
    alleles = np.zeros(max_allele, dtype=DTYPE)
    for f in genot_input.split(';'):
        pair = f.split("|")
        alleles[int(pair[0])] = int(pair[1])
    #logging.info(alleles)
    return alleles, max_allele

def generate_params(r, pref):
    """generates random parameters from given ranges"""
    down, up, cap, amp, eff = r
    small_number=1e-16 # to make the range exclusive, instead of inclusive
    d = np.random.uniform(down[0] + small_number, down[1])
    u = np.random.uniform(up[0] + small_number, up[1]) if pref else np.random.uniform(up[0] + small_number, d)
    c = np.random.uniform(cap[0] + small_number, cap[1])
    a = np.random.uniform(amp[0] + small_number, amp[1])
    p = np.random.uniform(eff[0] + small_number, eff[1])  # pcr-efficiency
    # logging.debug({'down': d, 'up': u, 'capture': c, 'amplification': a, 'efficiency': p})
    return {'down': d, 'up': u, 'capture': c, 'amplification': a, 'efficiency': p}


def cycle_allele(entry, params, floor):
    """ simulation of PCR cycle for a given allele
    Returns number of amplified molecules: template, stutter up and down (if any)
    entry - a tuple from a dictionary (k, v)
    params - dictionary with parameters for a given PCR
    """
    # logging.debug(entry)
    al, ct = entry
    if al > floor:
        # d, u, c, a, p = params
        pu = (1 - params['up']) ** al  # prob up stutter
        pd = (1 - params['down']) ** al  # prob down stutter
        pslip = 1 - pd * pu  # prob of slip
        pu_norm = (1 - pu) / (2 - pu - pd)  # norm prob up stutter
        np.random.seed()
        # number of molecules to which the polymerase bound, i.e. number of successes
        # where number of trials is ct and probability is PCR efficiency
        namp = np.random.binomial(ct, params['efficiency'])
        # number of slips, where number of trials is the number of times the polymerase
        # bound the molecule and probability is the probability of slip
        nslip = np.random.binomial(namp, pslip)
        # number of up stutters where number of trails is number of slips and
        # the probability is the normalized probability of stutter up
        nup = np.random.binomial(nslip, pu_norm)
        # logging.debug('pslip: %f, namp: %i, nslip: %i, nup: %i' %(pslip, namp, nslip, nup))
        ndown = nslip - nup
        ncorrect = namp - nslip
        res = [(al, ncorrect)]
        if ndown > 0: res.append((al - 1, ndown))
        if nup > 0: res.append((al + 1, nup))
        logging.debug(res)
        return res

def monte_carlo(max_n_reps, constants, ranges):
    """Runs Monte Carlo simulation of the PCR amplification until p_value threshold for the Mann Whitney test is reached or the the number of repetition reaches the maximum.

    Scheme:
    1) Run the first n repetitions.
    2) Calculate the highest p value for all the comparisons between set with the highest log likelihood median and others.
    3) Check if the highest p value with Bonferroni corrections is lower than the threshold. If true, stop. If false, go to step 1 with new n now equal to 4*n if the it's the even round of repetitions or 2*n it's the odd. That way the sop will be made every 100, 500, 1000, 5000 etc. repetitions.
    """
    pvalue_threshold = constants["pvalue_threshold"]
    results = list()
    run_reps = 0
    reps_round = 1
    reps = 100 if max_n_reps > 100 else max_n_reps
    while run_reps < max_n_reps:
        logging.debug("Starting two alleles simulation, number of reps: {}".format(reps))
        results.extend(list(map(
            one_repeat,
            repeat("two_alleles", reps),
            repeat(constants),
            repeat(ranges)
        )))
        logging.debug("Starting one allele simulation, number of reps: {}".format(reps))
        results.extend(list(map(
            one_repeat,
            repeat("one_allele", reps),
            repeat(constants),
            repeat(ranges)
        )))
        results_pd = pd.DataFrame.from_records(results)
        # get the allele for which the median log likelihood is the highest 
        highest_loglike = results_pd.groupby(6)[2].median().sort_values(ascending=False).head(n=1).index[0]
        # get the set of other alleles
        other_alleles = set(results_pd[6]) - set([highest_loglike])
        high_pval = 0
        n_tests = 0
        for a, b in product([highest_loglike], other_alleles):
            stat, pval = mannwhitneyu(
                results_pd.groupby(6)[2].get_group(a), 
                results_pd.groupby(6)[2].get_group(b), 
                alternative="greater"
            )
            n_tests += 1
            high_pval = max(pval, high_pval)
        # check if p_value threshold is satisfied, if it is finish the loop    
        high_pval *= n_tests
        run_reps += reps
        if high_pval < pvalue_threshold:
            logging.debug("Will break! P-value: {}".format(high_pval))
            break

        reps = 4*run_reps if reps_round % 2 == 1 else run_reps
        # make sure that the number of reps does not exceed the maximum number of reps
        reps = reps if reps + run_reps < max_n_reps else max_n_reps - run_reps
        reps_round+=1

    tmp = results_pd.groupby(6).get_group(highest_loglike).sort_values(0, ascending=False).head(n=1)

    # ident r2_squared likelihood highest_pval repetitions genotype best_guess parameters
    ret = "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}".format(
        tmp[0].item(), 
        tmp[1].item(), 
        tmp[3].item(),
        high_pval,
        run_reps,
        tmp[4].item(),
        tmp[6].item(), 
        tmp[5].item())
    return ret


# FUNCTIONS RUN EVERY SIMULATION
def one_repeat(str simulation_type, dict constants, tuple ranges):
    """Calls PCR simulation function, based on PCR products generates genotype and calculates model statistics"""
    cdef int total_molecule, first, second, genotype_total, max_allele, 
    cdef dict parameters
    cdef str initial
    cdef float identified, r2, prob_a
    cdef np.ndarray[DTYPE_t, ndim=1] alleles, alleles_nonzero, y_nonzero
    genotype_total = constants['genotype_total']
    max_allele = constants['max_allele']
    PCR_products = np.zeros(constants['max_allele'], dtype=DTYPE)
    parameters = generate_params(ranges, constants['up_preference'])
    alleles = constants['alleles']
    total_molecules = 0
    #Select initial molecules based on simulation parameters
    if simulation_type == "one_allele":
        if constants['random']:
            first = np.random.choice(alleles.nonzero()[0])
        else:
            # if not random, simulate PCR for an allele with max reads in the genotype
            first = np.argmax(alleles)
        # logging.info(PCR.max_allele)
        PCR_products[first] = constants['start_copies']
        initial = "{}, {}".format(first, first)
    else:
        logging.debug(len(alleles.nonzero()[0]))
        if len(alleles.nonzero()[0]) == 1: #if the input genotype consist of only one allele, not sure if that should be simulated... 
            first = np.argsort(-alleles)[0]
            second = np.random.choice([first-1, first+1])
        else:
            logging.debug("ELSE")
            if constants['random']:
                logging.debug("RANDOM")
                first, second = tuple(np.random.choice(alleles.nonzero()), 2)
            elif constants['half_random']:
                logging.debug("half_random")
                first = np.argsort(-alleles)[0]
                second = np.random.choice(np.nonzero(alleles)[0][np.nonzero(alleles)[0] != first])
            else:
                logging.debug("not random!")
                # if not random, simulate PCR for the alleles with max reads in the genotype
                logging.debug(np.argsort(-alleles)[1])
                first = np.argsort(-alleles)[0]
                second = np.argsort(-alleles)[1]
        PCR_products[first] = constants['start_copies'] / 2
        PCR_products[second] = constants['start_copies'] / 2
        logging.debug("Starting PCR with alleles: %d, %d" %(first, second))
        initial = "{}, {}".format(first, second)
    # PCR simulation

    PCR_products = simulate(PCR_products, constants, parameters)
    PCR_total_molecules = np.sum(PCR_products)

    # genotype generation
    mid = map(
        lambda al: list(repeat(
            al,
            np.random.binomial(genotype_total, PCR_products[al] / PCR_total_molecules)
        )),
        range(max_allele)
    )
    mid = list(chain.from_iterable(mid))
    
    loglike_a = mhl(alleles, PCR_products) if sum(PCR_products < alleles) == 0 else -999999
    like_a = e_const**loglike_a
    
    # pick from PCR pool genotype
    y = np.bincount(np.random.choice(mid, genotype_total))
    y.resize(max_allele)
    y_nonzero = y.nonzero()[0]
    
    # model statistics
    alleles_nonzero = alleles.nonzero()[0]
    identified = (sum([min(alleles[index], y[index]) for index in alleles_nonzero])) / genotype_total
    r2 = r2_score(alleles, y)
    genotype_report = ";".join(["|".join([str(i), str(y[i])]) for i in y_nonzero])
    report = [identified, r2, loglike_a, like_a, genotype_report, parameters, initial]
    #logging.debug("\t".join([str(h) for h in report]))
    #print("{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}".format(identified, r2, loglike_a, like_a, genotype_report, parameters, initial, simulation_type))
    return(report)


def simulate(np.ndarray products, dict constants, dict parameters):
    """Simulates PCR run, includes capture step if specified by PCR parameters
    """
    cdef int floor, ct, ct_up, al, n, namp, nslip, nup, ndown, ncorrect, cc
    cdef float up, down, efficiency, capture, pu, pd, pslip, pu_norm, floor_cap, cap_set, hit
    cdef np.ndarray[DTYPE_t, ndim=1] nzp, cs
    cc = constants['capture_cycle']
    floor = constants['floor']
    up = parameters['up']
    down = parameters['down']
    capture = parameters['capture']
    efficiency = parameters['efficiency']
    for cycle in range(1, constants['n_cycles']+1):
        # capture step
        if cycle == cc and len(products) > 1:
            nzp = products.nonzero()[0]
            cap_set = capture / (max(products) - min(nzp))
            floor_cap = 1 - (cap_set * len(nzp) / 2)
            n = 1
            for al in nzp:
                ct = products[al]
                hit = (floor_cap + cap_set * n) * ct
                ct_up = np.random.poisson(hit)
                ct_up = ct_up if ct_up < ct else ct
                products[al] = ct_up
                n+=1
        nzp = products.nonzero()[0]
        # cycle simulation for each allele
        for al in nzp:
            if al > floor:
                ct = products[al]
                pu = 1 - (1 - up) ** al  # prob up stutter
                pd = 1 - (1 - down) ** al  # prob down stutter
                pslip = 1 - (1 - pd) * (1 - pu)  # prob of slip
                pu_norm =  pu / (pu + pd)  # norm prob up stutter
                # logging.debug("ct: {0}, al: {1}, down: {2}, up: {3}".format(ct, al, params['down'], params['up']))
                np.random.seed(np.random.randint(1, 4294967295))
                # number of molecules to which the polymerase bound, i.e. number of successes
                # where number of trials is ct and probability is PCR efficiency
                namp = np.random.binomial(ct, efficiency)
                # number of slips, where number of trials is the number of times the polymerase
                # bound the molecule and probability is the probability of slip
                nslip = np.random.binomial(namp, pslip)
                # number of up stutters where number of trails is number of slips and
                # the probability is the normalized probability of stutter up
                nup = np.random.binomial(nslip, pu_norm)
                # logging.debug('pslip: %f, namp: %i, nslip: %i, nup: %i' %(pslip, namp, nslip, nup))
                ndown = nslip - nup
                ncorrect = namp - nslip
                # logging.debug("namp: {0}, ndown: {1}, nup: {2}, ncorrect: {3}".format(namp, ndown, nup, ncorrect))
                products[al] += ncorrect
                if ndown > 0: products[al - 1] += ndown
                if nup > 0: products[al + 1] += nup
    return products