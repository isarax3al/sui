#[test_only]
module bucket_v2_framework::sheet_tests;

use sui::sui::SUI;
use sui::balance;
use bucket_v2_framework::sheet::{Self, entity};

public struct TestLender has drop {}
public struct TestReceiver has drop {}
public struct Turnover has drop {}

#[test]
fun test_sheet() {

    // Test loan amount
    let loan_amount = 100_000_000_000; // 100 SUI

    // Create two separate sheets - one for lender, one for receiver
    let mut lender_sheet = sheet::new<SUI, TestLender>(TestLender {});
    assert!(lender_sheet.total_credit() == 0);
    assert!(lender_sheet.total_debt() == 0);
    let mut receiver_sheet = sheet::new<SUI, TestReceiver>(TestReceiver {});
    assert!(receiver_sheet.total_credit() == 0);
    assert!(receiver_sheet.total_debt() == 0);
    let mut turnover_sheet = sheet::new<SUI, Turnover>(Turnover {});
    assert!(turnover_sheet.total_credit() == 0);
    assert!(turnover_sheet.total_debt() == 0);

    // Add entities to both sheets so they can hold credits/debts
    // Lender's sheet must have receiver in credits map
    lender_sheet.add_debtor(entity<TestReceiver>(), TestLender {});
    lender_sheet.add_debtor(entity<TestReceiver>(), TestLender {});
    lender_sheet.add_creditor(entity<Turnover>(), TestLender {});
    lender_sheet.ban(entity<TestReceiver>(), TestLender {});
    lender_sheet.unban(entity<TestReceiver>(), TestLender {});
    lender_sheet.unban(entity<TestReceiver>(), TestLender {});
    // Receiver's sheet must have lender in debts map
    receiver_sheet.add_creditor(entity<TestLender>(), TestReceiver {});
    receiver_sheet.add_creditor(entity<TestLender>(), TestReceiver {});
    receiver_sheet.ban(entity<TestLender>(), TestReceiver {});
    receiver_sheet.unban(entity<TestLender>(), TestReceiver {});
    receiver_sheet.unban(entity<TestLender>(), TestReceiver {});
    // Insurance's sheet must have lender & debtor in debts map
    turnover_sheet.add_debtor(entity<TestLender>(), Turnover {});

    // Create a balance to lend
    let balance_to_lend = balance::create_for_testing<SUI>(loan_amount);

    // STEP 1: Execute lend operation on lender's sheet
    // This records credit against receiver in lender's sheet
    let loan = lender_sheet.lend(balance_to_lend, TestLender {});

    // Verify the loan was created correctly
    assert!(loan.value() == loan_amount);

    // Verify credit was recorded in lender's sheet against receiver
    assert!(lender_sheet.credits().contains(&entity<TestReceiver>()));
    assert!(lender_sheet.credits().get(&entity<TestReceiver>()).value() == loan_amount);
    assert!(lender_sheet.total_credit() == loan_amount);
    assert!(lender_sheet.total_debt() == 0);

    // Verify NO debt was recorded in lender's sheet
    assert!(!lender_sheet.debts().contains(&entity<TestLender>()));

    // STEP 2: Execute receive operation on receiver's sheet and burn the received balance
    let received_balance = receiver_sheet.receive(loan, TestReceiver {});
    received_balance.destroy_for_testing();

    // Verify debt was recorded in receiver's sheet against lender
    assert!(receiver_sheet.debts().contains(&entity<TestLender>()));
    assert!(receiver_sheet.debts().get(&entity<TestLender>()).value() == loan_amount);
    assert!(receiver_sheet.total_credit() == 0);
    assert!(receiver_sheet.total_debt() == loan_amount);

    // Verify NO credit was recorded in receiver's sheet
    assert!(!receiver_sheet.credits().contains(&entity<TestReceiver>()));

    // lender request debtor to repay
    let requested_amount = loan_amount * 3 / 4;
    let mut req = sheet::request<SUI, TestLender>(requested_amount, option::none(), TestLender {});
    assert!(req.requirement() == requested_amount);
    assert!(req.balance() == 0);
    assert!(req.shortage() == requested_amount);
    assert!(req.payer_debts().is_empty());

    // receiver repay part of it
    let mut balance_to_repay = balance::create_for_testing<SUI>(loan_amount/2);
    receiver_sheet.pay(&mut req, balance_to_repay.split(loan_amount/3), TestReceiver {});
    receiver_sheet.pay(&mut req, balance_to_repay, TestReceiver {});
    assert!(req.requirement() == requested_amount);
    assert!(req.balance() == loan_amount/2);
    assert!(req.shortage() == loan_amount/4);
    assert!(req.payer_debts().get(&entity<TestReceiver>()).value() == loan_amount/2);

    // treasury fill the shortage
    let balance_to_fill = balance::create_for_testing<SUI>(req.shortage());
    turnover_sheet.pay(&mut req, balance_to_fill, Turnover {});
    assert!(req.requirement() == requested_amount);
    assert!(req.balance() == requested_amount);
    assert!(req.shortage() == 0);
    assert!(req.payer_debts().get(&entity<Turnover>()).value() == loan_amount/4);

    // lender collect
    let received_balance = lender_sheet.collect(req, TestLender {});
    assert!(received_balance.value() == requested_amount);
    received_balance.destroy_for_testing();

    // Verify credit was updated in lender's sheet against receiver
    assert!(lender_sheet.credits().get(&entity<TestReceiver>()).value() == loan_amount/2);
    assert!(lender_sheet.debts().get(&entity<Turnover>()).value() == loan_amount/4);
    assert!(lender_sheet.total_credit() == loan_amount/2);
    assert!(lender_sheet.total_debt() == loan_amount/4);

    // Verify debt was updated in receiver's sheet against lender
    assert!(receiver_sheet.debts().get(&entity<TestLender>()).value() == loan_amount/2);
    assert!(receiver_sheet.total_credit() == 0);
    assert!(receiver_sheet.total_debt() == loan_amount/2);

    // Verify credit was updated in turnover's sheet against lender
    assert!(turnover_sheet.credits().get(&entity<TestLender>()).value() == loan_amount/4);
    assert!(turnover_sheet.total_credit() == loan_amount/4);
    assert!(turnover_sheet.total_debt() == 0);

    // Consume sheets to satisfy non-drop constraints
    lender_sheet.destroy_for_testing();
    receiver_sheet.destroy_for_testing();
    turnover_sheet.destroy_for_testing();
}

#[test, expected_failure(abort_code = sheet::EPayTooMuch)]
fun test_pay_too_much() {

    // Test loan amount
    let loan_amount = 100_000_000_000; // 100 SUI

    // Create two separate sheets - one for lender, one for receiver
    let mut lender_sheet = sheet::new<SUI, TestLender>(TestLender {});
    let mut receiver_sheet = sheet::new<SUI, TestReceiver>(TestReceiver {});

    // Add entities to both sheets so they can hold credits/debts
    // Lender's sheet must have receiver in credits map
    lender_sheet.add_debtor(entity<TestReceiver>(), TestLender {});
    // Receiver's sheet must have lender in debts map
    receiver_sheet.add_creditor(entity<TestLender>(), TestReceiver {});

    // Create a balance to lend
    let balance_to_lend = balance::create_for_testing<SUI>(loan_amount);

    // STEP 1: Execute lend operation on lender's sheet
    // This records credit against receiver in lender's sheet
    let loan = lender_sheet.lend(balance_to_lend, TestLender {});

    // STEP 2: Execute receive operation on receiver's sheet and burn the received balance
    let received_balance = receiver_sheet.receive(loan, TestReceiver {});
    received_balance.destroy_for_testing();

    // lender request debtor to repay
    let requested_amount = loan_amount / 2;
    let mut req = sheet::request<SUI, TestLender>(requested_amount, option::none(), TestLender {});

    // receiver repay part of it
    let balance_to_repay = balance::create_for_testing<SUI>(requested_amount + 1);
    receiver_sheet.pay(&mut req, balance_to_repay, TestReceiver {});

    let received_balance = lender_sheet.collect(req, TestLender {});
    received_balance.destroy_for_testing();

    lender_sheet.destroy_for_testing();
    receiver_sheet.destroy_for_testing();
}

#[test, expected_failure(abort_code = sheet::EInvalidEntityForDebt)]
fun test_not_creditor() {

    // Test loan amount
    let loan_amount = 100_000_000_000; // 100 SUI

    // Create two separate sheets - one for lender, one for receiver
    let mut lender_sheet = sheet::new<SUI, TestLender>(TestLender {});
    let mut receiver_sheet = sheet::new<SUI, TestReceiver>(TestReceiver {});

    lender_sheet.add_debtor(entity<TestReceiver>(), TestLender {});

    // Create a balance to lend
    let balance_to_lend = balance::create_for_testing<SUI>(loan_amount);

    // STEP 1: Execute lend operation on lender's sheet
    // This records credit against receiver in lender's sheet
    let loan = lender_sheet.lend(balance_to_lend, TestLender {});

    // STEP 2: Execute receive operation on receiver's sheet and burn the received balance
    let received_balance = receiver_sheet.receive(loan, TestReceiver {});
    received_balance.destroy_for_testing();

    lender_sheet.destroy_for_testing();
    receiver_sheet.destroy_for_testing();
}

#[test, expected_failure(abort_code = sheet::EInvalidEntityForCredit)]
fun test_not_debtor() {

    // Test loan amount
    let loan_amount = 100_000_000_000; // 100 SUI

    // Create two separate sheets - one for lender, one for receiver
    let mut lender_sheet = sheet::new<SUI, TestLender>(TestLender {});
    let mut receiver_sheet = sheet::new<SUI, TestReceiver>(TestReceiver {});

    receiver_sheet.add_creditor(entity<TestLender>(), TestReceiver {});

    // Create a balance to lend
    let balance_to_lend = balance::create_for_testing<SUI>(loan_amount);

    // STEP 1: Execute lend operation on lender's sheet
    // This records credit against receiver in lender's sheet
    let loan = lender_sheet.lend(balance_to_lend, TestLender {});

    // STEP 2: Execute receive operation on receiver's sheet and burn the received balance
    let received_balance = receiver_sheet.receive(loan, TestReceiver {});
    received_balance.destroy_for_testing();

    lender_sheet.destroy_for_testing();
    receiver_sheet.destroy_for_testing();
}

#[test, expected_failure(abort_code = sheet::EInvalidEntityForDebt)]
fun test_banned_creditor() {

    // Test loan amount
    let loan_amount = 100_000_000_000; // 100 SUI

    // Create two separate sheets - one for lender, one for receiver
    let mut lender_sheet = sheet::new<SUI, TestLender>(TestLender {});
    let mut receiver_sheet = sheet::new<SUI, TestReceiver>(TestReceiver {});

    lender_sheet.add_debtor(entity<TestReceiver>(), TestLender {});
    receiver_sheet.add_creditor(entity<TestLender>(), TestReceiver {});
    receiver_sheet.ban(entity<TestLender>(), TestReceiver {});
    receiver_sheet.ban(entity<TestLender>(), TestReceiver {});

    // Create a balance to lend
    let balance_to_lend = balance::create_for_testing<SUI>(loan_amount);

    // STEP 1: Execute lend operation on lender's sheet
    // This records credit against receiver in lender's sheet
    let loan = lender_sheet.lend(balance_to_lend, TestLender {});

    // STEP 2: Execute receive operation on receiver's sheet and burn the received balance
    let received_balance = receiver_sheet.receive(loan, TestReceiver {});
    received_balance.destroy_for_testing();

    lender_sheet.destroy_for_testing();
    receiver_sheet.destroy_for_testing();
}

#[test, expected_failure(abort_code = sheet::EInvalidEntityForCredit)]
fun test_banned_debtor() {

    // Test loan amount
    let loan_amount = 100_000_000_000; // 100 SUI

    // Create two separate sheets - one for lender, one for receiver
    let mut lender_sheet = sheet::new<SUI, TestLender>(TestLender {});
    let mut receiver_sheet = sheet::new<SUI, TestReceiver>(TestReceiver {});

    lender_sheet.add_debtor(entity<TestReceiver>(), TestLender {});
    lender_sheet.ban(entity<TestReceiver>(), TestLender {});
    lender_sheet.ban(entity<TestReceiver>(), TestLender {});
    receiver_sheet.add_creditor(entity<TestLender>(), TestReceiver {});

    // Create a balance to lend
    let balance_to_lend = balance::create_for_testing<SUI>(loan_amount);

    // STEP 1: Execute lend operation on lender's sheet
    // This records credit against receiver in lender's sheet
    let loan = lender_sheet.lend(balance_to_lend, TestLender {});

    // STEP 2: Execute receive operation on receiver's sheet and burn the received balance
    let received_balance = receiver_sheet.receive(loan, TestReceiver {});
    received_balance.destroy_for_testing();

    lender_sheet.destroy_for_testing();
    receiver_sheet.destroy_for_testing();
}

#[test, expected_failure(abort_code = sheet::EChecklistNotFulfill)]
fun test_checklist_not_fulfill() {

    // Test loan amount
    let loan_amount = 100_000_000_000; // 100 SUI

    // Create two separate sheets - one for lender, one for receiver
    let mut lender_sheet = sheet::new<SUI, TestLender>(TestLender {});
    let mut receiver_sheet = sheet::new<SUI, TestReceiver>(TestReceiver {});
    let mut turnover_sheet = sheet::new<SUI, Turnover>(Turnover {});

    // Add entities to both sheets so they can hold credits/debts
    // Lender's sheet must have receiver in credits map
    lender_sheet.add_debtor(entity<TestReceiver>(), TestLender {});
    lender_sheet.add_creditor(entity<Turnover>(), TestLender {});
    // Receiver's sheet must have lender in debts map
    receiver_sheet.add_creditor(entity<TestLender>(), TestReceiver {});
    // Insurance's sheet must have lender & debtor in debts map
    turnover_sheet.add_debtor(entity<TestLender>(), Turnover {});

    // Create a balance to lend
    let balance_to_lend = balance::create_for_testing<SUI>(loan_amount);

    // STEP 1: Execute lend operation on lender's sheet
    // This records credit against receiver in lender's sheet
    let loan = lender_sheet.lend(balance_to_lend, TestLender {});

    // STEP 2: Execute receive operation on receiver's sheet and burn the received balance
    let received_balance = receiver_sheet.receive(loan, TestReceiver {});
    received_balance.destroy_for_testing();

    // lender request debtor to repay
    let requested_amount = loan_amount * 3 / 4;
    let mut req = sheet::request<SUI, TestLender>(
        requested_amount,
        option::some(vector[entity<TestLender>(), entity<Turnover>()]),
        TestLender {},
    );
    
    // treasury fill the shortage
    let balance_to_fill = balance::create_for_testing<SUI>(loan_amount/4);
    turnover_sheet.pay(&mut req, balance_to_fill, Turnover {});

    // receiver repay part of it
    let balance_to_repay = balance::create_for_testing<SUI>(loan_amount/2);
    receiver_sheet.pay(&mut req, balance_to_repay, TestReceiver {});

    // lender collect
    let received_balance = lender_sheet.collect(req, TestLender {});
    received_balance.destroy_for_testing();

    // Consume sheets to satisfy non-drop constraints
    lender_sheet.destroy_for_testing();
    receiver_sheet.destroy_for_testing();
    turnover_sheet.destroy_for_testing();
}